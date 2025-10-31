"""
Elasticsearch Throughput Monitor (10-Minute Version with Average Summary)
--------------------------------------------------------------------------
This script monitors how many documents are indexed in a specific Elasticsearch index over time.
It queries the _count API every few seconds, stores the results in a CSV file, and computes:
- Instantaneous ingestion rate (docs/s)
- Average throughput over the full 10-minute window

Useful for verifying Chaos Mesh experiments — e.g., to measure the impact of network delay or bandwidth limits.
"""

import time
import csv
import requests
# import matplotlib.pyplot as plt
from datetime import datetime

# -------------------- CONFIGURATION --------------------
ES_URL = "http://localhost:9200/test/_count"   # Elasticsearch index _count API endpoint
USERNAME = "elastic"                           # ES username
PASSWORD = "changeme"                          # ES password
INTERVAL = 1                                   # seconds between queries
DURATION = 660                                 # total duration: 10 minutes (600s)
CSV_FILE = "es_throughput_10min.csv"           # output CSV filename
# -------------------------------------------------------

timestamps, counts, rates = [], [], []
start = time.time()
previous_count = None
previous_time = start

# Open CSV file for writing
with open(CSV_FILE, mode='w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(["timestamp", "elapsed_seconds", "count", "rate_docs_per_sec"])  # CSV header

    print(f"Monitoring Elasticsearch index throughput for {DURATION/60:.0f} minutes ...")
    print(f"Sampling every {INTERVAL}s. Results will be saved to '{CSV_FILE}'\n")

    while time.time() - start < DURATION:
        now = time.time()
        elapsed = now - start

        try:
            r = requests.get(ES_URL, auth=(USERNAME, PASSWORD))
            r.raise_for_status()
            count = r.json().get('count', 0)
        except Exception as e:
            print(f"⚠️  Error: {e}")
            count = None

        # Compute ingestion rate (docs per second)
        rate = None
        if count is not None and previous_count is not None:
            rate = (count - previous_count) / (now - previous_time)
        
        # Store results
        timestamps.append(elapsed)
        counts.append(count)
        rates.append(rate)
        
        # Write to CSV
        writer.writerow([
            datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            round(elapsed, 2),
            count,
            round(rate, 4) if rate is not None else ""
        ])

        # Print live info
        if rate is not None:
            print(f"{time.strftime('%H:%M:%S')} | Count: {count} | Rate: {rate:.2f} docs/s")
        else:
            print(f"{time.strftime('%H:%M:%S')} | Count: {count}")

        # Prepare for next iteration
        previous_count = count
        previous_time = now
        time.sleep(INTERVAL)

# -------------------- SUMMARY --------------------
# Compute average throughput ignoring None values
valid_rates = [r for r in rates if r is not None]
avg_throughput = sum(valid_rates) / len(valid_rates) if valid_rates else 0

# Print and append to CSV
summary_line = ["AVERAGE", "", "", round(avg_throughput, 4)]
with open(CSV_FILE, mode='a', newline='') as f:
    writer = csv.writer(f)
    writer.writerow([])
    writer.writerow(summary_line)

print(f"\nData collection complete. Results saved to '{CSV_FILE}'")
print(f"Average throughput over {DURATION/60:.0f} minutes: {avg_throughput:.2f} docs/s")

# # -------------------- PLOT RESULTS --------------------
# plt.figure(figsize=(10, 5))
# plt.plot(timestamps, counts, '-o', label='Total documents')
# plt.xlabel('Time (s)')
# plt.ylabel('Indexed documents')
# plt.title('Elasticsearch Document Count Over 10 Minutes')
# plt.grid()
# plt.legend()
# plt.show()