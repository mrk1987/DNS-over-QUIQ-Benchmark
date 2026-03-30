#!/bin/bash

# DNS DoQ Benchmark Script (Direct resolver queries - bypasses local caching)
# Usage: bash dns_doq_benchmark.sh [queries] [concurrent_threads]

QUERIES=${1:-100}
THREADS=${2:-5}
TEST_DOMAINS=("example.com" "google.com" "cloudflare.com" "wikipedia.org" "github.com")

declare -a RESOLVERS=(
    "quic://dns.adguard-dns.com"
    "quic://dns.alidns.com:853"
    "quic://dns.caliph.dev:853"
    "quic://dns.comss.one"
    "quic://dns.dnsguard.pub"
    "quic://dns.jupitrdns.com"
    "quic://dns.surfsharkdns.com"
    "quic://doh.tiar.app"
    "quic://doq.ffmuc.net"
    "quic://family.adguard-dns.com"
    "quic://ibksturm.synology.me"
    "quic://juuri.hagezi.org"
    "quic://root.hagezi.org"
    "quic://router.comss.one"
    "quic://rx.techomespace.com"
    "quic://unfiltered.adguard-dns.com"
    "quic://wurzn.hagezi.org"
    "quic://dns.nextdns.io"
    "quic://dns0.eu"
    "quic://dns.cloudflare.com"
    "quic://one.one.one.one"
    "quic://dns.google"
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

echo -e "${BLUE}=== DNS DoQ Benchmark Suite (Direct Resolver Queries) ===${NC}"
echo "Queries per resolver: $QUERIES"
echo "Concurrent threads: $THREADS"
echo "Domains: ${TEST_DOMAINS[@]}"
echo ""

# Install drill (ldns) if missing - better for direct DoQ queries
if ! command -v drill &> /dev/null; then
    echo -e "${YELLOW}[*] Installing ldns-tools (drill)...${NC}"
    apt-get update -qq 2>/dev/null
    apt-get install -y ldns-tools -qq 2>/dev/null
fi

echo -e "${BLUE}[*] Running benchmarks...${NC}"
echo ""

benchmark_resolver() {
    local resolver=$1
    local host="${resolver#quic://}"
    host="${host%:*}"
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
            
            # Use drill with explicit resolver and DoQ (port 853)
            # drill queries the specific resolver directly
            timeout 6 drill -D @$host -p $port $domain A > /dev/null 2>&1
            result=$?
            
            end_ns=$(date +%s%N)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
            
            if [ $result -eq 0 ]; then
                echo "1:$elapsed_ms" >> "$TEMP_DIR/${resolver//\//-}.results"
            else
                echo "0:$elapsed_ms" >> "$TEMP_DIR/${resolver//\//-}.results"
            fi
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
            if [ "$exit_code" -eq 1 ]; then
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
    
    # Color output based on success
    if [ "$success" -gt 0 ]; then
        printf "${GREEN}✓${NC} [%-35s] %3d/%d | avg: %6.1fms | p95: %6.1fms | p99: %6.1fms | stdev: %5.2f\n" "$resolver" "$success" "$QUERIES" "$avg" "$p95" "$p99" "$stdev"
    else
        printf "${RED}✗${NC} [%-35s] %3d/%d | FAILED\n" "$resolver" "$success" "$QUERIES"
    fi
    
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
echo "Top 10 by latency (100% success only):"
tail -n +2 "$RESULTS_FILE" | awk -F',' '$3 == $2 {print}' | sort -t',' -k6 -n | head -10 | awk -F',' '{printf "%-35s %3d/%d | %7.2fms avg | %7.2fms p95 | %7.2fms p99 | %5.2f stdev\n", $1, $3, $2, $6, $8, $9, $10}'
