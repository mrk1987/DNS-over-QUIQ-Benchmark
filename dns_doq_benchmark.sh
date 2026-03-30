#!/bin/bash

# DNS DoQ Benchmark Script (using kdig)
# Usage: bash dns_doq_benchmark.sh [queries] [concurrent_threads]

QUERIES=${1:-100}
THREADS=${2:-5}
TEST_DOMAINS=("example.com" "google.com" "cloudflare.com")

declare -a RESOLVERS=(
    "dns.adguard-dns.com"
    "dns.alidns.com:853"
    "dns.caliph.dev:853"
    "dns.comss.one"
    "dns.dnsguard.pub"
    "dns.jupitrdns.com"
    "dns.surfsharkdns.com"
    "doh.tiar.app"
    "doq.ffmuc.net"
    "family.adguard-dns.com"
    "ibksturm.synology.me"
    "juuri.hagezi.org"
    "root.hagezi.org"
    "router.comss.one"
    "rx.techomespace.com"
    "unfiltered.adguard-dns.com"
    "wurzn.hagezi.org"
    "dns.nextdns.io"
    "dns0.eu"
    "dns.cloudflare.com"
    "one.one.one.one"
    "dns.google"
)

TIMESTAMP=$(date +%s)
RESULTS_FILE="dns-benchmark-${TIMESTAMP}.csv"
TEMP_DIR="/tmp/dns-bench-$$"
mkdir -p "$TEMP_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== DNS DoQ Benchmark Suite ===${NC}"
echo "Queries per resolver: $QUERIES"
echo "Concurrent threads: $THREADS"
echo ""

# Install kdig if missing
if ! command -v kdig &> /dev/null; then
    echo -e "${YELLOW}[*] Installing knot-resolver...${NC}"
    apt-get update -qq 2>/dev/null
    apt-get install -y knot-resolver -qq 2>/dev/null
fi

echo -e "${BLUE}[*] Running benchmarks...${NC}"
echo ""

benchmark_resolver() {
    local resolver=$1
    local host="${resolver%:*}"
    local port="${resolver##*:}"
    [[ "$port" == "$host" ]] && port="853"
    
    local success=0
    local failures=0
    local timings=()
    
    # Run queries in parallel
    for ((i=0; i<QUERIES; i++)); do
        domain="${TEST_DOMAINS[$((i % ${#TEST_DOMAINS[@]}))]}"
        
        (
            start_ns=$(date +%s%N)
            kdig +quic "@$host" -p "$port" "$domain" A +timeout=5 +tries=1 > /dev/null 2>&1
            result=$?
            end_ns=$(date +%s%N)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
            echo "$result:$elapsed_ms" >> "$TEMP_DIR/${resolver//\//-}.results"
        ) &
        
        # Limit concurrent jobs
        if (( (i+1) % THREADS == 0 )); then
            wait
        fi
    done
    
    wait
    
    # Parse results
    if [ -f "$TEMP_DIR/${resolver//\//-}.results" ]; then
        local timings_arr=()
        while IFS=: read -r exit_code elapsed; do
            if [ "$exit_code" -eq 0 ]; then
                ((success++))
                timings_arr+=("$elapsed")
            else
                ((failures++))
            fi
        done < "$TEMP_DIR/${resolver//\//-}.results"
        
        # Calculate stats with awk
        if [ ${#timings_arr[@]} -gt 0 ]; then
            {
                printf "%s\n" "${timings_arr[@]}"
            } | awk -v q="$QUERIES" -v s="$success" '
            {
                sum += $1
                count++
                arr[count] = $1
            }
            END {
                if (count > 0) {
                    avg = sum / count
                    
                    # Variance for stdev
                    for (i = 1; i <= count; i++) {
                        diff = arr[i] - avg
                        sq_sum += diff * diff
                    }
                    stdev = sqrt(sq_sum / count)
                    
                    # Bubble sort for percentiles
                    for (i = 1; i <= count; i++) {
                        for (j = i + 1; j <= count; j++) {
                            if (arr[i] > arr[j]) {
                                temp = arr[i]
                                arr[i] = arr[j]
                                arr[j] = temp
                            }
                        }
                    }
                    
                    p50_idx = int(count * 0.50)
                    p95_idx = int(count * 0.95)
                    p99_idx = int(count * 0.99)
                    if (p50_idx == 0) p50_idx = 1
                    if (p95_idx == 0) p95_idx = 1
                    if (p99_idx == 0) p99_idx = 1
                    
                    p50 = arr[p50_idx]
                    p95 = arr[p95_idx]
                    p99 = arr[p99_idx]
                    
                    success_rate = (s / q) * 100
                    printf "%.2f,%.2f,%.2f,%.2f,%.2f,%.1f", avg, p50, p95, p99, stdev, success_rate
                }
            }' > "$TEMP_DIR/${resolver//\//-}.stats"
        fi
    fi
    
    # Read calculated stats
    local avg=0 p50=0 p95=0 p99=0 stdev=0 success_rate=0
    if [ -f "$TEMP_DIR/${resolver//\//-}.stats" ]; then
        IFS=',' read -r avg p50 p95 p99 stdev success_rate < "$TEMP_DIR/${resolver//\//-}.stats"
    fi
    
    printf "[%-30s] %3d/%d | avg: %6.1fms | p95: %6.1fms | p99: %6.1fms\n" "$resolver" "$success" "$QUERIES" "$avg" "$p95" "$p99"
    
    echo "$resolver,$QUERIES,$success,$failures,$success_rate,$avg,$p50,$p95,$p99,$stdev"
}

# CSV header + results
{
    echo "Resolver,Queries,Success,Failures,SuccessRate_%,AvgMs,P50Ms,P95Ms,P99Ms,StdevMs"
    
    for resolver in "${RESOLVERS[@]}"; do
        benchmark_resolver "$resolver"
    done
} | tee "$RESULTS_FILE"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo -e "${GREEN}✓ Benchmark complete!${NC}"
echo "Results: $RESULTS_FILE"
echo ""
echo "Top 10 by latency:"
tail -n +2 "$RESULTS_FILE" | sort -t',' -k6 -n | head -10 | awk -F',' '{printf "%-30s %7.2fms %7.2fms %6.1f%%\n", $1, $6, $8, $5}'
