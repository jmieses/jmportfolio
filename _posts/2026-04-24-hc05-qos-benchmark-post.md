---
layout: post
title: "HC-05 QoS Benchmarking with an Elegoo Uno R3: From Bidirectional Validation to Distance and Wall Experiments"
date: 2026-04-24
categories: [embedded-systems, communications, arduino]
tags: [hc-05, bluetooth, uart, qos, telemetry, arduino, ubuntu, python, benchmarking]
excerpt: "A full engineering write-up of how I validated and benchmarked an HC-05 Bluetooth link with an Elegoo Uno R3, including Ubuntu setup, debugging failures, final firmware and scripts, and a discussion of latency, jitter, goodput, and reliability across 1 m, 3 m, 5 m, and wood-wall conditions."
---

# HC-05 QoS Benchmarking with an Elegoo Uno R3: From Bidirectional Validation to Distance and Wall Experiments

This project started as a Bluetooth LED demo and evolved into a full **end-to-end communication benchmark**. The final goal was not just to toggle an LED over Bluetooth, but to build, validate, and measure a **bidirectional telemetry path** between an Ubuntu host and an Elegoo Uno R3 through an HC-05 Bluetooth module.

The benchmark was designed from an engineering perspective. I wanted a workflow that I could reproduce, modify, and extend later to other boards, other telemetry methods, and other environmental conditions. The result was a stop-and-wait QoS experiment that measured:

- **round-trip time (RTT)**
- **jitter**
- **packet loss**
- **goodput**

under four conditions:

- **1 m**
- **3 m**
- **5 m**
- **one interior wood wall**

This post documents the full process, including the setup, the challenges I faced, the debugging path, the final firmware and scripts, and a detailed discussion of the results.

---

## 1. Engineering goal

The system under test was:

**Ubuntu host → Bluetooth RFCOMM/SPP → HC-05 → UART → Uno firmware → UART → HC-05 → Bluetooth RFCOMM/SPP → Ubuntu host**

That full round-trip path matters because it is the actual system I care about. I was not trying to measure “Bluetooth speed” in isolation. I was trying to measure the real behavior of a low-cost embedded telemetry path that includes:

- the host Bluetooth stack
- the HC-05 serial bridge
- the UART interface
- the Uno firmware
- the return path back to the host

That distinction shaped the whole experiment.

---

## 2. System under test

### Hardware

- Elegoo Uno R3
- HC-05 Bluetooth module
- breadboard and jumper wires
- LED on pin 8 for early validation
- resistor divider on the **Uno TX → HC-05 RXD** path

### Host environment

- Ubuntu 20.04
- Python 3.11
- Android Bluetooth terminal app for validation
- Arduino IDE for firmware upload

### Why the voltage divider mattered

The return path from the Uno back into the HC-05 depended on the line:

**Uno TX → voltage divider → HC-05 RXD**

This turned out to be one of the most important details in the entire project. A bad solder connection in that divider caused the system to behave like a one-way link at first, even though the LED demo seemed to work.

---

## 3. Wiring summary

My working UART wiring was:

- **HC-05 TXD → Uno pin 10**  
- **Uno pin 11 → voltage divider → HC-05 RXD**  
- **GND shared between Uno and HC-05**  
- **LED on pin 8** for visual validation during early development

I used `SoftwareSerial` instead of pins 0 and 1 because I wanted to keep the USB serial path separate from the Bluetooth path during debugging.

### Why I did not use pins 0 and 1

On an Uno-class board, pins 0 and 1 are tied to the main hardware UART and the onboard USB interface. That is convenient for some projects, but it is inconvenient when I want to:

- keep USB serial available for local debug
- keep Bluetooth on a separate path
- avoid confusing USB serial traffic with Bluetooth serial traffic

Using `SoftwareSerial` on pins 10 and 11 made the behavior much easier to reason about.

---

## 4. Early validation: one-way control is not enough

My first success case was simple Bluetooth LED control. I could use a phone app to send `1` and `0`, and the LED would turn on and off. At first glance, that looked like success.

But this only proved the **forward path**:

**host → HC-05 → HC-05 TXD → Uno RX → LED**

It did **not** prove the reverse path:

**Uno TX → HC-05 RXD → Bluetooth host**

That distinction became the central debugging lesson of the project.

---

## 5. Ubuntu setup and host-side configuration

Before the benchmark could run, I had to make Ubuntu communicate reliably with the HC-05.

### 5.1 Pairing and trusting the HC-05

I used `bluetoothctl` to discover, pair, and trust the module.

Typical flow:

```text
bluetoothctl
power on
agent on
scan on
pair 00:14:03:05:0A:0C
trust 00:14:03:05:0A:0C
info 00:14:03:05:0A:0C
```

From this, I confirmed that Ubuntu could see the HC-05 and that the module exposed the expected serial service.

### 5.2 Early RFCOMM device experiments

Initially, I also experimented with an RFCOMM device path like:

```text
/dev/rfcomm0
```

using:

```bash
sudo rfcomm bind 0 00:14:03:05:0A:0C 1
```

This did work sometimes, but it introduced extra Linux session-management complexity. The device path could disappear after resets or reboots, and there were permission issues too.

### 5.3 Why I moved to direct Python Bluetooth sockets

The cleanest host-side solution ended up being a **direct Bluetooth RFCOMM socket in Python** rather than relying on `/dev/rfcomm0`.

This was better for the benchmark because:

- the Python program directly controlled connection setup
- there was no extra serial-device layer to manage
- timing logic stayed in the same process that created the packets

That made the benchmark cleaner and easier to reproduce.

---

## 6. Challenges I faced and how I solved them

This project looked simple at first, but most of the engineering value came from the failures.

### 6.1 Ubuntu pairing was not the same as a usable session

One challenge was learning that:

- `Paired: yes`
- `Trusted: yes`

did **not** automatically mean:

- the HC-05 was currently connected
- the Python benchmark could open a working session

A reboot or module reset could leave the pairing information intact while the live session still had to be re-established.

#### How I handled it

I separated two concepts:

- **persistent relationship state**: pairing and trust
- **live session state**: current connection

That mental separation made troubleshooting much easier.

---

### 6.2 Python environment mismatch on Ubuntu

At one point I installed `pyserial`, but `sudo python3 ...` could not find the module. The issue was that `pyserial` had been installed into my user Python environment, while `sudo` was using the root Python environment.

#### How I handled it

I stopped mixing root execution with user-installed packages and standardized on:

```bash
python3.11 -m pip install --user <package>
```

for the Python 3.11 environment I was actually using.

---

### 6.3 The LED demo made the system look healthier than it really was

A very important hardware isolation test was this:

- when I disconnected the **HC-05 RXD** path from the divider, the phone app could still turn the LED on and off
- when I disconnected the **HC-05 TXD** path from the Uno, LED control stopped working

That told me the LED demo only depended on:

**HC-05 TXD → Uno RX**

and that the reverse path was still unverified.

#### Engineering lesson

A one-way command demo can hide a broken return path. For telemetry work, that is not enough.

---

### 6.4 The real root cause: a bad voltage divider connection

The biggest actual hardware fault was the return path:

**Uno TX → voltage divider → HC-05 RXD**

I had originally soldered the divider resistors together, but the joint was bad. That meant the Uno could receive commands through the HC-05, but it could not reliably transmit data back into the HC-05.

#### How I solved it

I rebuilt the divider using fresh resistors:

- **1 kΩ**
- **2 kΩ**

Then I checked the divider output and confirmed it was approximately **3.3 V** at the junction. After rebuilding that part of the circuit, both Android and Python could successfully receive echoed bytes from the Uno.

That was the moment the project moved from “Bluetooth LED control” to **validated bidirectional communication**.

---

### 6.5 Power reset sometimes fixed connection issues

During testing, I noticed that a power reset of the Uno/HC-05 sometimes cleared connection issues. I cannot say that every failure was caused by stale module state, but in practice a quick power cycle often restored a clean connection path.

#### Engineering takeaway

When working with small serial Bluetooth modules, a simple power reset can be a practical troubleshooting step before blaming the whole software stack.

---

## 7. Verification workflow before benchmarking

Before I trusted the benchmark, I verified the full path with both:

- an **Android Bluetooth terminal app**
- a **Python RFCOMM socket test on Ubuntu**

That mattered because it separated:

- Linux host-side issues
- firmware issues
- hardware return-path issues

If both Android and Ubuntu could send a byte and receive the echo back, then I knew the system was ready for the actual benchmark.

---

## 8. Benchmark design

Once the bidirectional path worked, I moved to the actual experiment.

### 8.1 Why I used a stop-and-wait echo experiment

The benchmark used a **stop-and-wait** design:

1. Ubuntu sends one packet
2. Uno receives and validates the packet
3. Uno echoes the packet back immediately
4. Ubuntu timestamps the round trip
5. Ubuntu sends the next packet

This is a strong first benchmarking design because it keeps the measurement simple and unambiguous.

### 8.2 Packet format

I used a structured binary packet instead of loose bytes:

```text
START | SEQ_H | SEQ_L | LEN | PAYLOAD | CHECKSUM
```

Where:

- `START` = fixed start byte (`0x7E`)
- `SEQ_H`, `SEQ_L` = 16-bit sequence number
- `LEN` = payload length
- `PAYLOAD` = useful data bytes
- `CHECKSUM` = XOR checksum

This let me detect:

- missing replies
- corrupted replies
- sequence mismatches
- payload mismatches

### 8.3 Metrics

For each condition, I measured:

- **mean RTT**
- **minimum RTT**
- **maximum RTT**
- **jitter** (RTT standard deviation)
- **loss ratio**
- **goodput**

### 8.4 Payload sizes

I used four payload sizes:

- 1 byte
- 8 bytes
- 32 bytes
- 64 bytes

### 8.5 Conditions

I ran the benchmark under four conditions:

- **1 m**
- **3 m**
- **5 m**
- **one interior wood wall**

The wall condition used a simple wood wall in my house.

---

## 9. Final benchmark firmware

This is the final Uno firmware used for the packet-echo benchmark.

<details>
<summary><strong>Uno benchmark firmware</strong></summary>

```cpp
#include <SoftwareSerial.h>

SoftwareSerial BT(10, 11); // RX, TX

const uint8_t START_BYTE = 0x7E;
const uint8_t MAX_PAYLOAD = 64;
const unsigned long BYTE_TIMEOUT_MS = 50;

bool readByteWithTimeout(Stream &s, uint8_t &out, unsigned long timeoutMs) {
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    if (s.available()) {
      out = (uint8_t)s.read();
      return true;
    }
  }
  return false;
}

uint8_t computeChecksum(uint16_t seq, uint8_t len, const uint8_t *payload) {
  uint8_t cs = (uint8_t)(seq >> 8) ^ (uint8_t)(seq & 0xFF) ^ len;
  for (uint8_t i = 0; i < len; i++) {
    cs ^= payload[i];
  }
  return cs;
}

void setup() {
  BT.begin(9600);
}

void loop() {
  static uint8_t payload[MAX_PAYLOAD];

  if (!BT.available()) {
    return;
  }

  uint8_t startByte = (uint8_t)BT.read();
  if (startByte != START_BYTE) {
    return;
  }

  uint8_t seqHi, seqLo, len, rxChecksum;

  if (!readByteWithTimeout(BT, seqHi, BYTE_TIMEOUT_MS)) return;
  if (!readByteWithTimeout(BT, seqLo, BYTE_TIMEOUT_MS)) return;
  if (!readByteWithTimeout(BT, len, BYTE_TIMEOUT_MS)) return;

  if (len > MAX_PAYLOAD) {
    return;
  }

  for (uint8_t i = 0; i < len; i++) {
    if (!readByteWithTimeout(BT, payload[i], BYTE_TIMEOUT_MS)) return;
  }

  if (!readByteWithTimeout(BT, rxChecksum, BYTE_TIMEOUT_MS)) return;

  uint16_t seq = ((uint16_t)seqHi << 8) | seqLo;
  uint8_t calcChecksum = computeChecksum(seq, len, payload);

  if (calcChecksum != rxChecksum) {
    return;
  }

  // Echo packet back unchanged
  BT.write(START_BYTE);
  BT.write(seqHi);
  BT.write(seqLo);
  BT.write(len);
  BT.write(payload, len);
  BT.write(calcChecksum);
}
```
</details>

### Why the firmware is minimal

I intentionally removed extra debug printing and unnecessary behavior during timed runs. That makes the measured RTT reflect the communication path rather than debug overhead.

---

## 10. Python benchmark script

This is the host-side benchmark script that created the raw and summary CSV files.

<details>
<summary><strong>Ubuntu Python benchmark script</strong></summary>

```python
import socket
import time
import csv
import statistics

HC05_ADDR = "00:14:03:05:0A:0C"
RFCOMM_CHANNEL = 1

START_BYTE = 0x7E
TIMEOUT_S = 1.0

TRIALS_PER_PAYLOAD = 100
PAYLOAD_SIZES = [1, 8, 32, 64]

def compute_checksum(seq, payload):
    cs = ((seq >> 8) & 0xFF) ^ (seq & 0xFF) ^ len(payload)
    for b in payload:
        cs ^= b
    return cs & 0xFF

def build_packet(seq, payload):
    return bytes([
        START_BYTE,
        (seq >> 8) & 0xFF,
        seq & 0xFF,
        len(payload)
    ]) + payload + bytes([compute_checksum(seq, payload)])

def recv_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("Socket closed while receiving data")
        data.extend(chunk)
    return bytes(data)

def read_packet(sock):
    while True:
        b = recv_exact(sock, 1)
        if b[0] == START_BYTE:
            break

    header = recv_exact(sock, 3)
    seq = (header[0] << 8) | header[1]
    length = header[2]

    payload = recv_exact(sock, length)
    rx_checksum = recv_exact(sock, 1)[0]

    calc = compute_checksum(seq, payload)
    if calc != rx_checksum:
        raise ValueError("Checksum mismatch")

    return seq, payload

def summarize(values):
    if not values:
        return None
    return {
        "count": len(values),
        "mean_ms": statistics.mean(values),
        "min_ms": min(values),
        "max_ms": max(values),
        "stdev_ms": statistics.stdev(values) if len(values) > 1 else 0.0
    }

def connect_with_retries(max_attempts=5, delay_s=3.0):
    last_error = None

    for attempt in range(1, max_attempts + 1):
        sock = socket.socket(
            socket.AF_BLUETOOTH,
            socket.SOCK_STREAM,
            socket.BTPROTO_RFCOMM
        )
        sock.settimeout(10.0)

        try:
            print(f"Connect attempt {attempt}/{max_attempts}...")
            sock.connect((HC05_ADDR, RFCOMM_CHANNEL))
            print("Connected.")
            return sock
        except Exception as e:
            last_error = e
            print(f"Connect attempt failed: {e}")
            sock.close()
            if attempt < max_attempts:
                print(f"Waiting {delay_s} seconds before retry...")
                time.sleep(delay_s)

    raise last_error

def main():
    sock = connect_with_retries()
    all_results = []

    try:
        time.sleep(1.0)

        with open("hc05_qos_raw_results.csv", "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                "payload_size",
                "trial",
                "sequence",
                "success",
                "rtt_ms",
                "error"
            ])

            seq = 0

            for payload_size in PAYLOAD_SIZES:
                print(f"\nTesting payload size = {payload_size} bytes")
                rtts = []
                successes = 0
                condition_start = time.perf_counter()

                for trial in range(TRIALS_PER_PAYLOAD):
                    payload = bytes((trial + i) % 256 for i in range(payload_size))
                    packet = build_packet(seq, payload)

                    try:
                        t0 = time.perf_counter_ns()
                        sock.sendall(packet)

                        rx_seq, rx_payload = read_packet(sock)
                        t1 = time.perf_counter_ns()

                        if rx_seq != seq:
                            raise ValueError(f"Sequence mismatch: expected {seq}, got {rx_seq}")

                        if rx_payload != payload:
                            raise ValueError("Payload mismatch")

                        rtt_ms = (t1 - t0) / 1e6
                        rtts.append(rtt_ms)
                        successes += 1
                        writer.writerow([payload_size, trial, seq, 1, rtt_ms, ""])

                    except Exception as e:
                        writer.writerow([payload_size, trial, seq, 0, "", str(e)])

                    seq = (seq + 1) & 0xFFFF

                elapsed = time.perf_counter() - condition_start
                loss_ratio = (TRIALS_PER_PAYLOAD - successes) / TRIALS_PER_PAYLOAD
                goodput = (successes * payload_size) / elapsed

                stats = summarize(rtts)

                print(f"  Successes: {successes}/{TRIALS_PER_PAYLOAD}")
                print(f"  Loss ratio: {loss_ratio:.4f}")
                print(f"  Goodput: {goodput:.2f} bytes/sec")

                if stats:
                    print(f"  Mean RTT: {stats['mean_ms']:.3f} ms")
                    print(f"  Min RTT:  {stats['min_ms']:.3f} ms")
                    print(f"  Max RTT:  {stats['max_ms']:.3f} ms")
                    print(f"  Jitter (stdev): {stats['stdev_ms']:.3f} ms")

                all_results.append({
                    "payload_size": payload_size,
                    "successes": successes,
                    "trials": TRIALS_PER_PAYLOAD,
                    "loss_ratio": loss_ratio,
                    "goodput_Bps": goodput,
                    "mean_rtt_ms": stats["mean_ms"] if stats else None,
                    "min_rtt_ms": stats["min_ms"] if stats else None,
                    "max_rtt_ms": stats["max_ms"] if stats else None,
                    "jitter_stdev_ms": stats["stdev_ms"] if stats else None
                })

        with open("hc05_qos_summary.csv", "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                "payload_size",
                "successes",
                "trials",
                "loss_ratio",
                "goodput_Bps",
                "mean_rtt_ms",
                "min_rtt_ms",
                "max_rtt_ms",
                "jitter_stdev_ms"
            ])
            for row in all_results:
                writer.writerow([
                    row["payload_size"],
                    row["successes"],
                    row["trials"],
                    row["loss_ratio"],
                    row["goodput_Bps"],
                    row["mean_rtt_ms"],
                    row["min_rtt_ms"],
                    row["max_rtt_ms"],
                    row["jitter_stdev_ms"]
                ])

    finally:
        sock.close()

if __name__ == "__main__":
    main()
```
</details>

---

## 11. Reusable analysis and plotting workflow

To analyze the benchmark results, I created a reusable plotting script that combines multiple `hc05_qos_summary*.csv` and `hc05_qos_raw_results*.csv` files and generates:

- trend plots from summary CSVs
- boxplots from raw CSVs
- RTT histograms
- RTT ECDF plots
- RTT vs trial scatter plots

In my repository, I keep the reusable plotter as a separate script so I can apply it to future experiment variations without rewriting the plotting code each time.

Example command:

```bash
python3.11 hc05_qos_plotter_extended.py --input-dir ./results --output-dir ./plots
```

---

## 12. Reproduction guide

This is the exact workflow I would recommend to reproduce the experiment.

### Step 1: build and validate the hardware

- wire the HC-05 to the Uno using `SoftwareSerial` pins 10 and 11
- build the voltage divider on the **Uno TX → HC-05 RXD** path
- verify the divider output is about **3.3 V**
- confirm common ground

### Step 2: upload the benchmark firmware

Upload the benchmark echo firmware to the Uno.

### Step 3: configure Ubuntu

- pair and trust the HC-05 with `bluetoothctl`
- make sure no other device is connected to the HC-05
- standardize on Python 3.11 if that is your chosen environment

### Step 4: verify bidirectional communication

Before benchmarking, run a simple socket validation from Ubuntu and confirm:

- sending a byte changes the LED or validation response
- the Uno echoes data back

### Step 5: run the benchmark

For each condition:

- place the Ubuntu machine at the target location
- keep the HC-05/Uno fixed
- run the benchmark script
- save the raw and summary CSV outputs

### Step 6: analyze results

Run the plotter across the collected files and review:

- mean RTT
- jitter
- goodput
- maximum RTT
- packet loss
- raw distribution plots

---

## 13. Experimental results

All conditions completed with **100/100 successful replies at every payload size**, which means the measured **packet loss ratio was 0.0 in all tested cases**.

### 13.1 Summary table

| Payload | Condition  | Successes | Loss | Mean RTT (ms) | Jitter SD (ms) | Goodput (B/s) | Max RTT (ms) |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 B  | 1 m        | 100/100 | 0.0 | 41.25 | 7.08 | 24.22 | 71.34 |
| 8 B  | 1 m        | 100/100 | 0.0 | 52.63 | 4.98 | 151.89 | 71.20 |
| 32 B | 1 m        | 100/100 | 0.0 | 101.38 | 3.79 | 315.51 | 121.13 |
| 64 B | 1 m        | 100/100 | 0.0 | 172.17 | 3.43 | 371.64 | 190.06 |
| 1 B  | 3 m        | 100/100 | 0.0 | 40.85 | 8.45 | 24.46 | 71.29 |
| 8 B  | 3 m        | 100/100 | 0.0 | 55.76 | 6.65 | 143.39 | 79.94 |
| 32 B | 3 m        | 100/100 | 0.0 | 104.95 | 7.43 | 304.81 | 149.91 |
| 64 B | 3 m        | 100/100 | 0.0 | 173.06 | 6.49 | 369.73 | 218.79 |
| 1 B  | 5 m        | 100/100 | 0.0 | 48.42 | 12.09 | 20.64 | 97.35 |
| 8 B  | 5 m        | 100/100 | 0.0 | 64.12 | 14.93 | 124.72 | 132.54 |
| 32 B | 5 m        | 100/100 | 0.0 | 112.52 | 15.63 | 284.32 | 182.49 |
| 64 B | 5 m        | 100/100 | 0.0 | 184.71 | 28.22 | 346.42 | 376.21 |
| 1 B  | Wood wall  | 100/100 | 0.0 | 41.64 | 7.90 | 24.00 | 76.45 |
| 8 B  | Wood wall  | 100/100 | 0.0 | 56.82 | 8.52 | 140.70 | 98.91 |
| 32 B | Wood wall  | 100/100 | 0.0 | 103.85 | 5.25 | 308.03 | 125.28 |
| 64 B | Wood wall  | 100/100 | 0.0 | 172.67 | 4.35 | 370.56 | 193.71 |

---

## 14. Plots

> **Important:** update the image paths below to match your GitHub Pages asset folder.  
> I used `/assets/images/hc05/` as an example.

### Mean RTT vs payload size

![Mean RTT vs payload size](/assets/images/hc05/hc05_mean_rtt_vs_payload.png)

### Jitter vs payload size

![Jitter vs payload size](/assets/images/hc05/hc05_jitter_vs_payload.png)

### Goodput vs payload size

![Goodput vs payload size](/assets/images/hc05/hc05_goodput_vs_payload.png)

### Maximum RTT vs payload size

![Maximum RTT vs payload size](/assets/images/hc05/hc05_max_rtt_vs_payload.png)

### Packet loss vs payload size

![Packet loss vs payload size](/assets/images/hc05/hc05_loss_vs_payload.png)

### RTT boxplots by payload

![RTT boxplots by payload](/assets/images/hc05/hc05_rtt_boxplots_by_payload.png)

### RTT ECDF by payload

![RTT ECDF by payload](/assets/images/hc05/hc05_rtt_ecdf_by_payload.png)

### RTT histograms by payload

![RTT histograms by payload](/assets/images/hc05/hc05_rtt_histograms_by_payload.png)

### RTT vs trial number

![RTT vs trial number](/assets/images/hc05/hc05_rtt_vs_trial_scatter.png)

---

## 15. Results and discussion

### 15.1 Reliability

The first and strongest result is that **all tested conditions had 0% packet loss**. For every payload size and every condition, the benchmark returned **100 successful echoes out of 100 trials**.

That means the degradation mechanisms in this experiment did **not** show up as dropped packets. Instead, they showed up as changes in timing and efficiency.

From an engineering standpoint, this is important because it tells me the HC-05 + Uno path remained functionally reliable across the tested indoor scenarios. The performance story is therefore about **latency and predictability**, not raw connectivity failure.

### 15.2 Mean RTT increased with payload size in every condition

The mean RTT plot shows a clear and expected monotonic pattern: as payload size increased, mean RTT increased.

That is exactly what I would expect from a stop-and-wait serial echo benchmark. Larger packets take longer to:

- leave the host
- cross the Bluetooth serial bridge
- traverse UART
- be parsed and echoed by the Uno
- return through the same path

The important point is that the **shape** of the RTT-vs-payload curve was consistent across all tested conditions. This suggests the benchmark behaved coherently and the underlying communication model was stable.

### 15.3 Distance affected timing more than reliability

The 5 m condition was the clearest stress case.

At **5 m**, mean RTT was the highest for every payload size:

- 1 B: **48.42 ms**
- 8 B: **64.12 ms**
- 32 B: **112.52 ms**
- 64 B: **184.71 ms**

That is not a catastrophic increase, but it is a real one.

However, the more important effect of distance was not just the rise in mean RTT. It was the rise in **timing variability**.

### 15.4 Jitter was the most sensitive indicator of degradation

The jitter plot was one of the most informative figures in the whole experiment.

The **1 m** condition had the lowest overall jitter, especially at larger payloads:

- 32 B: **3.79 ms**
- 64 B: **3.43 ms**

The **5 m** condition had the highest jitter by far:

- 1 B: **12.09 ms**
- 8 B: **14.93 ms**
- 32 B: **15.63 ms**
- 64 B: **28.22 ms**

That last number is especially important. The 64-byte payload at 5 m did not just get slower on average — it became much less predictable.

This suggests that in my setup, increasing distance primarily degraded **timing consistency**, not packet delivery.

### 15.5 Worst-case latency at 5 m was much worse than the average

The maximum RTT plot and the boxplots both show that the **5 m** condition produced the most severe outliers.

The strongest example is:

- **64 B at 5 m:** max RTT = **376.21 ms**

That is dramatically higher than:

- **64 B at 1 m:** max RTT = **190.06 ms**
- **64 B at wood wall:** max RTT = **193.71 ms**

So although the average RTT at 5 m was only moderately higher than baseline, the **worst-case behavior** was substantially worse.

This matters because many real embedded applications care about occasional high-latency events, not just the mean.

### 15.6 The wood wall condition was a mild obstacle, not a severe one

The wall condition used a **simple interior wood wall**. Under that condition, the system still had:

- **0% packet loss**
- mean RTT values very close to 1 m and 3 m
- jitter much lower than the 5 m case
- max RTT values close to baseline

For example:

- **64 B mean RTT**
  - 1 m: **172.17 ms**
  - wood wall: **172.67 ms**
  - 5 m: **184.71 ms**

- **64 B jitter**
  - 1 m: **3.43 ms**
  - wood wall: **4.35 ms**
  - 5 m: **28.22 ms**

This tells me that, in my environment, the simple wood wall introduced only **mild degradation**. Distance to 5 m was clearly the more stressful condition.

### 15.7 Goodput improved with payload size, but degraded with distance

The goodput plot shows another intuitive but important result.

Larger payloads gave better goodput because fixed per-packet overhead was amortized over more useful data. That is why:

- 1-byte payloads had the lowest goodput
- 64-byte payloads had the highest goodput

However, the 5 m condition consistently underperformed the shorter-range cases. For example:

- **64 B goodput**
  - 1 m: **371.64 B/s**
  - 3 m: **369.73 B/s**
  - wood wall: **370.56 B/s**
  - 5 m: **346.42 B/s**

So the link stayed reliable at 5 m, but it became less efficient.

### 15.8 Boxplots, ECDFs, histograms, and scatter plots tell the deeper story

The raw-data plots were very helpful because they showed things the summary table could not show by itself.

#### Boxplots

The boxplots show that:

- 1 m and wood wall stayed relatively tight
- 3 m widened somewhat
- 5 m had the broadest spreads and the largest outliers

#### ECDF plots

The ECDF plots make it easy to see that the 5 m curves are generally **shifted right** and often **flatter**, which means:

- more delay
- more variability

The wood wall curves overlapped strongly with 1 m and 3 m, reinforcing the idea that it was a mild obstacle.

#### Histograms

The histograms show that the 5 m condition developed broader RTT distributions and longer tails, especially for larger payloads.

#### Trial scatter plots

One important positive result is that the scatter plots do **not** show strong systematic drift over trial number. The spikes are scattered across the run rather than steadily increasing over time.

That suggests the timing variability was condition-related rather than caused by a simple warm-up drift or continuous degradation across the trial sequence.

### 15.9 Main engineering conclusion

The overall engineering conclusion is:

> Under the tested indoor conditions, the HC-05 + Elegoo Uno R3 link remained highly reliable from 1 m out to 5 m and across a wood-wall condition, with zero packet loss in all tested cases. The main degradation mechanism was not packet delivery failure, but increased latency variability and reduced efficiency, especially at 5 m and especially for larger payloads.

That is a useful result because it is more nuanced than “Bluetooth worked” or “Bluetooth failed.” It tells me how the link behaves as conditions get harder.

---

## 16. What I would improve or test next

Now that I have a clean benchmark workflow, the next logical experiments are:

- compare different **UART baud rates**
- compare the same HC-05 workflow on a **different board**
- add a more severe obstacle than a wood wall
- test with robot motors or a noisier electrical environment
- compare HC-05 against another telemetry method

The current experiment gives me a reproducible baseline to compare against.

---

## 17. Final reflection

The most important lesson from this project is that a simple Bluetooth demo can hide a lot of real engineering work.

The final system looked small:

- one Uno
- one HC-05
- one laptop
- one benchmark script

But getting to a trustworthy result required solving problems in:

- host configuration
- Bluetooth session management
- Python environment consistency
- UART directionality
- physical-layer signal conditioning
- firmware design
- packet structure
- benchmarking methodology
- plot interpretation

The visible output may have started as an LED, but the actual deliverable was a **reproducible communication benchmark**.

---

## 18. Assets to include in the repository

To make the project easy to follow, I recommend keeping these in the repository alongside the post:

- the benchmark firmware
- the benchmark Python script
- the plotting script
- raw CSV files
- summary CSV files
- generated plots
- wiring / schematic image
- this markdown post

That way the post becomes both a write-up and a practical guide someone else can follow.

