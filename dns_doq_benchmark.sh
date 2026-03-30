#!/bin/bash

# DNS DoQ Benchmark Script
# Usage: bash dns_doq_benchmark.sh [queries] [concurrent_threads] [timeout_ms]
# Default: 100 queries, 5 threads, 5000ms timeout

QUERIES=${1:-100}
THREADS=${2:-5}
TIMEOUT_MS=${3:-5000}
TEST_DOMAINS=("example.com" "google.com" "cloudflare.com")

# Resolvers: 24 total (17 original + 7 new/additional)
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
REACHABILITY_FILE="dns-reachability-${TIMESTAMP}.txt"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== DNS DoQ Benchmark Suite ===${NC}"
echo "Queries per resolver: $QUERIES"
echo "Concurrent threads: $THREADS"
echo "Timeout: ${TIMEOUT_MS}ms"
echo ""

# Check dependencies
check_deps() {
    local missing=0
    
    if ! command -v dig &> /dev/null; then
        echo -e "${RED}[!] dig not found${NC}"
        missing=1
    fi
    
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}[!] python3 not found${NC}"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        echo -e "${YELLOW}Installing dependencies...${NC}"
        apt-get update -qq
        apt-get install -y dnsutils python3 python3-pip > /dev/null 2>&1
        pip3 install dnspython requests --quiet 2>/dev/null || true
    fi
}

check_deps

# Reachability check (UDP 853)
echo -e "${BLUE}[*] Reachability check...${NC}"
{
    echo "Resolver,Reachable,Host,Port,Timestamp"
    for resolver in "${RESOLVERS[@]}"; do
        host="${resolver%:*}"
        port="${resolver##*:}"
        [[ "$port" == "$host" ]] && port="853"
        
        timeout 2 bash -c "echo '' > /dev/udp/$host/$port" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓${NC} $host:$port"
            echo "$resolver,YES,$host,$port,$TIMESTAMP" >> "$REACHABILITY_FILE"
        else
            echo -e "${RED}✗${NC} $host:$port"
            echo "$resolver,NO,$host,$port,$TIMESTAMP" >> "$REACHABILITY_FILE"
        fi
    done
} 2>/dev/null

echo ""
echo -e "${BLUE}[*] Running benchmarks (this may take a few minutes)...${NC}"
echo ""

# Python benchmark script (embedded)
python3 << 'PYTHON_SCRIPT'
import subprocess
import json
import csv
import time
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from statistics import median, stdev, mean
import os

RESOLVERS = [
    "dns.adguard-dns.com",
    "dns.alidns.com:853",
    "dns.caliph.dev:853",
    "dns.comss.one",
    "dns.dnsguard.pub",
    "dns.jupitrdns.com",
    "dns.surfsharkdns.com",
    "doh.tiar.app",
    "doq.ffmuc.net",
    "family.adguard-dns.com",
    "ibksturm.synology.me",
    "juuri.hagezi.org",
    "root.hagezi.org",
    "router.comss.one",
    "rx.techomespace.com",
    "unfiltered.adguard-dns.com",
    "wurzn.hagezi.org",
    "dns.nextdns.io",
    "dns0.eu",
    "dns.cloudflare.com",
    "one.one.one.one",
    "dns.google"
]

TEST_DOMAINS = ["example.com", "google.com", "cloudflare.com"]
QUERIES = int(sys.argv[1]) if len(sys.argv) > 1 else 100
TIMEOUT_MS = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
TIMEOUT_S = TIMEOUT_MS / 1000.0
RESULTS_FILE = sys.argv[3] if len(sys.argv) > 3 else "dns-benchmark.csv"

results = []

def query_resolver(resolver, domain, timeout):
    """Query single resolver with timeout"""
    host = resolver.split(':')[0]
    port = resolver.split(':')[1] if ':' in resolver else '853'
    
    start = time.perf_counter()
    try:
        # Use dig with specific timeout and server
        result = subprocess.run(
            ['dig', f'@{host}', '-p', port, '+tcp', domain, '+timeout=2', '+tries=1'],
            capture_output=True,
            timeout=timeout,
            text=True
        )
        elapsed = (time.perf_counter() - start) * 1000
        
        if 'NOERROR' in result.stdout or 'ANSWER SECTION' in result.stdout:
            return {'success': True, 'latency': elapsed, 'error': None}
        else:
            return {'success': False, 'latency': elapsed, 'error': 'NXDOMAIN/SERVFAIL'}
    except subprocess.TimeoutExpired:
        elapsed = (time.perf_counter() - start) * 1000
        return {'success': False, 'latency': elapsed, 'error': 'TIMEOUT'}
    except Exception as e:
        elapsed = (time.perf_counter() - start) * 1000
        return {'success': False, 'latency': elapsed, 'error': str(e)[:30]}

def benchmark_resolver(resolver):
    """Benchmark single resolver"""
    print(f"  Testing {resolver}...", end='', flush=True)
    
    timings = []
    failures = 0
    
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = []
        for i in range(QUERIES):
            domain = TEST_DOMAINS[i % len(TEST_DOMAINS)]
            future = executor.submit(query_resolver, resolver, domain, TIMEOUT_S)
            futures.append(future)
        
        for future in as_completed(futures):
            result = future.result()
            if result['success']:
                timings.append(result['latency'])
            else:
                failures += 1
    
    success_count = len(timings)
    success_rate = (success_count / QUERIES) * 100 if QUERIES > 0 else 0
    
    if timings:
        avg_ms = mean(timings)
        p50_ms = median(timings)
        sorted_timings = sorted(timings)
        p95_ms = sorted_timings[int(len(timings) * 0.95)] if len(timings) > 1 else timings[0]
        p99_ms = sorted_timings[int(len(timings) * 0.99)] if len(timings) > 1 else timings[0]
        stdev_ms = stdev(timings) if len(timings) > 1 else 0
    else:
        avg_ms = p50_ms = p95_ms = p99_ms = stdev_ms = 0
    
    result_dict = {
        'Resolver': resolver,
        'Queries': QUERIES,
        'Success': success_count,
        'Failures': failures,
        'SuccessRate_%': round(success_rate, 1),
        'AvgMs': round(avg_ms, 2),
        'P50Ms': round(p50_ms, 2),
        'P95Ms': round(p95_ms, 2),
        'P99Ms': round(p99_ms, 2),
        'StdevMs': round(stdev_ms, 2)
    }
    
    print(f" {success_count}/{QUERIES} | avg: {avg_ms:.1f}ms | p95: {p95_ms:.1f}ms")
    return result_dict

# Run benchmarks
for resolver in RESOLVERS:
    result = benchmark_resolver(resolver)
    results.append(result)

# Write CSV
with open(RESULTS_FILE, 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=results[0].keys())
    writer.writeheader()
    writer.writerows(results)

print(f"\n✓ Results exported to {RESULTS_FILE}")

# Print summary table
print("\n=== SUMMARY (sorted by avg latency) ===")
sorted_results = sorted(results, key=lambda x: x['AvgMs'])
print(f"{'Resolver':<30} {'Success':<10} {'AvgMs':<10} {'P95Ms':<10} {'StdevMs':<10}")
print("-" * 70)
for r in sorted_results[:10]:
    print(f"{r['Resolver']:<30} {r['Success']}/{r['Queries']:<8} {r['AvgMs']:<10.2f} {r['P95Ms']:<10.2f} {r['StdevMs']:<10.2f}")

PYTHON_SCRIPT

# Display reachability summary
echo ""
echo -e "${BLUE}=== REACHABILITY SUMMARY ===${NC}"
if [ -f "$REACHABILITY_FILE" ]; then
    reachable=$(grep ",YES," "$REACHABILITY_FILE" | wc -l)
    unreachable=$(grep ",NO," "$REACHABILITY_FILE" | wc -l)
    echo -e "${GREEN}Reachable: $reachable${NC}"
    echo -e "${RED}Unreachable: $unreachable${NC}"
    echo "Reachability details saved to: $REACHABILITY_FILE"
fi

echo ""
echo -e "${GREEN}✓ Benchmark complete!${NC}"
echo "Results: $RESULTS_FILE"
echo "Reachability: $REACHABILITY_FILE"
