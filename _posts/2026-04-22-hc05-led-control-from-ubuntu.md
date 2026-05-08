---
title: "Bidirectional Bluetooth Command Path Validation with HC-05 and Elegoo Uno R3"
date: 2026-04-22
classes: wide
excerpt: "An engineering-focused build log on validating a bidirectional Bluetooth command path using an HC-05 and an Elegoo Uno R3, including serial-interface debugging, Linux host integration, and the hardware root cause that blocked reverse telemetry."
---

This project began as a simple Bluetooth LED demo, but it quickly became a more interesting engineering problem: **how to validate a full bidirectional command-and-telemetry path between a host machine and an embedded target**.

At a high level, the goal was to send commands wirelessly from a host device to an **Elegoo Uno R3** through an **HC-05 Bluetooth module**, drive a visible hardware output, and then verify that the microcontroller could also send data back over the same Bluetooth link. That last part turned out to be the critical difference between a one-way control demo and a real telemetry foundation.

What looked like a basic “turn an LED on over Bluetooth” exercise ultimately became a focused debugging effort involving:

* UART signal direction and interface ownership
* Bluetooth Serial Port Profile behavior
* Ubuntu host communication
* Arduino software architecture
* physical-layer debugging on the return path
* voltage-divider integrity and signal validation

From an engineering perspective, the final result was more valuable than the original demo because it validated the complete communication chain needed for future **QoS / telemetry experiments**.

## Why I chose the HC-05

I chose the **HC-05** because it is one of the most approachable modules for learning Bluetooth communication at the embedded-systems level. The key advantage is that it behaves like a **serial bridge**: the Bluetooth side presents a Serial Port Profile (SPP) connection, and the embedded side presents a UART interface. In other words, it lets a wireless link look like an emulated serial cable over RFCOMM. ([Bluetooth® Technology Website][1])

That made it a good fit for what I wanted to learn:

* how Bluetooth commands map into UART bytes
* how to debug a communication path layer by layer
* how to verify both control and return telemetry
* how to prepare a simple embedded platform for later performance benchmarking

I intentionally chose something simpler than BLE or Wi-Fi because I wanted the communication model to stay visible rather than abstracted away.

## Project objective

The immediate functional objective was straightforward:

* send `'1'` over Bluetooth to turn an LED on
* send `'0'` over Bluetooth to turn an LED off

But the real engineering objective was broader:

> Validate a complete bidirectional data path from a host device to an Uno R3 through an HC-05, and isolate any failure to the correct layer: host setup, Bluetooth link, UART wiring, firmware parsing, or return telemetry.

That distinction mattered a lot. A one-way LED demo is useful, but it is not enough for telemetry or QoS experiments. For future latency, jitter, and packet-loss work, the system needs to support:

1. host sends data
2. Uno receives data
3. Uno responds back
4. host timestamps and logs the reply

So the final milestone for this project was not “the LED turns on,” but rather:

**Ubuntu / Android → HC-05 → Uno → HC-05 → Ubuntu / Android**

## Hardware and software stack

### Hardware

* Elegoo Uno R3
* HC-05 Bluetooth module
* LED
* current-limiting resistor for the LED
* resistor divider on the Uno TX → HC-05 RX path
* breadboard and jumper wires

[Image suggestion: Add a photo or diagram of the breadboard setup showing the Uno, HC-05, LED, resistors, and wiring connections.]

### Software / host environments

* Arduino IDE
* Android Bluetooth terminal app
* Ubuntu 20.04
* Python 3.11
* Python RFCOMM socket testing

The Arduino Uno R3 is based on the ATmega328P and provides 14 digital I/O pins, 6 analog inputs, a USB connection, and a 16 MHz clock, which made it a convenient board for a small communication-path prototype. ([Arduino Documentation][2])

## System architecture

At a functional level, the system looks like this:

**Host terminal / Python script → Bluetooth SPP link → HC-05 → UART → Uno firmware → LED output**

And for the return path:

**Uno firmware → UART → HC-05 → Bluetooth SPP link → host terminal / Python script**

[Image suggestion: Add a block diagram illustrating the communication flow, with arrows showing data paths from host to Uno and back, labeling components like HC-05, UART, etc.]

This mattered because it gave me a disciplined way to debug the system. Instead of treating the project as one black box, I could isolate it into layers:

1. **Host layer**
   Android app or Ubuntu/Python

2. **Bluetooth layer**
   HC-05 pairing, connection, and RFCOMM/SPP transport

3. **UART layer**
   HC-05 TXD/RXD to Uno RX/TX

4. **Firmware layer**
   character parsing, LED control, echo behavior

5. **Output layer**
   visible LED state change

That layered mental model made it much easier to understand what was actually failing at each stage.

## Why I did not keep Bluetooth on pins 0 and 1

One of the first practical lessons in the project was that on an Arduino Uno-class board, the main hardware UART is on **digital pins 0 (RX) and 1 (TX)**, and that UART is also connected to the onboard USB interface. That creates a conflict if I want to use the USB serial monitor for debugging while also using Bluetooth on the same serial path. Arduino’s documented SoftwareSerial example exists specifically to let you create an additional serial path on other digital pins. ([Arduino Documentation][2])

So instead of sharing the hardware UART, I used:

```cpp
SoftwareSerial BT(10, 11); // RX, TX
```

That let me keep the Bluetooth link separate from USB serial debugging and gave me a much cleaner test setup.

## First implementation: one-way Bluetooth LED control

The first successful milestone was a basic LED control sketch. The Uno listened for characters coming from the HC-05 and mapped them to LED state changes.

### Initial LED control sketch

```cpp
#include <SoftwareSerial.h>

SoftwareSerial BT(10, 11); // RX, TX
const int LED = 8;

void setup() {
  Serial.begin(9600);
  BT.begin(9600);
  pinMode(LED, OUTPUT);
  Serial.println("Bluetooth LED test ready");
}

void loop() {
  if (BT.available()) {
    char c = BT.read();

    Serial.print("Received: ");
    Serial.println(c);

    if (c == '1') {
      digitalWrite(LED, HIGH);
      Serial.println("LED ON");
    } 
    else if (c == '0') {
      digitalWrite(LED, LOW);
      Serial.println("LED OFF");
    }
  }
}
```

This was useful because it proved the basic command path worked. From an Android app, I could send `1` and `0` and see the LED change state.

However, this sketch only verified **one-way control**. It did **not** prove that the Uno could send data back through the HC-05.

That distinction became the core of the debugging process.

## Ubuntu host configuration: what I had to do to connect to the HC-05

Before I could test the system from Python, I had to make the Ubuntu machine recognize and connect to the HC-05 as a Bluetooth serial target.

### Step 1: confirm the HC-05 was discoverable

I used `bluetoothctl`, which is the standard BlueZ command-line control tool for Bluetooth on Linux. It supports commands such as `devices`, `power`, `scan`, `agent`, `pair`, `trust`, and `connect`. ([Debian Manpages][3])

The basic discovery flow I used was:

```text
bluetoothctl
power on
agent on
scan on
```

Once scanning was active, Ubuntu discovered the module and identified it as:

```text
DSD TECH HC-05
```

with the Bluetooth address:

```text
00:14:03:05:0A:0C
```

[Image suggestion: Add a screenshot of the bluetoothctl scan output showing the HC-05 device discovery.]

### Step 2: pair and trust the HC-05

After discovery, I paired the module using:

```text
pair 00:14:03:05:0A:0C
```

When prompted for the PIN code, I used:

```text
1234
```

After the pairing succeeded, I marked the device as trusted:

```text
trust 00:14:03:05:0A:0C
```

That matters because a trusted device is easier to reconnect to on later sessions. The `bluetoothctl` documentation explicitly includes `trust <dev>` as the command to trust a device. ([Debian Manpages][3])

[Image suggestion: Add a screenshot of the bluetoothctl info output showing the paired and trusted status.]

### Step 3: verify the module exposed the right service

After pairing, I used:

```text
info 00:14:03:05:0A:0C
```

to inspect the module. The important result was that Ubuntu reported the **Serial Port** UUID:

```text
00001101-0000-1000-8000-00805f9b34fb
```

That was exactly what I wanted to see, because the HC-05 is supposed to expose Bluetooth Serial Port Profile functionality. This matched the SPP behavior I expected from the module. ([Bluetooth® Technology Website][1])

### Step 4: experiment with RFCOMM device binding

My first Linux-side approach was to treat the HC-05 as a serial device via RFCOMM. For that I used `rfcomm`, which Ubuntu documents as the utility used to set up, maintain, and inspect RFCOMM configuration for the Linux Bluetooth subsystem. ([Ubuntu Manpages][4])

The binding flow I used was:

```bash
sudo rfcomm bind 0 00:14:03:05:0A:0C 1
ls -l /dev/rfcomm0
rfcomm -a
```

When this worked, Ubuntu created:

```text
/dev/rfcomm0
```

and I could see the module associated with RFCOMM channel 1.

[Image suggestion: Add a screenshot of the terminal output after running rfcomm bind and ls commands, showing /dev/rfcomm0 created.]

### Step 5: deal with Linux device permissions

Once `/dev/rfcomm0` appeared, it was initially owned by root and not directly accessible from my user Python environment. So for quick testing I temporarily changed the permissions:

```bash
sudo chmod 666 /dev/rfcomm0
```

This was only a temporary development convenience, but it let me continue testing without switching my Python environment to root.

---

## Challenges I faced during the Ubuntu configuration process

The Ubuntu-side configuration worked eventually, but not without friction. The following were the main challenges and how I resolved them.

### Challenge 1: the device was discovered, but not immediately available for pairing

The first time I tried to pair, I got a “device not available” style message because I attempted the pair command before the scan results had fully stabilized.

### How I solved it

I simply let the scan continue until the HC-05 appeared clearly by name and address, then retried the pairing command. Once it was visible as:

```text
DSD TECH HC-05
```

the pairing succeeded normally.

### Challenge 2: `rfcomm` state was not persistent or obvious

At several points, I had a situation where:

* the device was paired and trusted
* but `/dev/rfcomm0` did not exist
* or it existed in one moment and disappeared later
* or `rfcomm -a` returned no active device

This was especially noticeable after resets or restarts.

### How I solved it

I learned to separate two different ideas:

* **pairing/trust state**, which persisted
* **live RFCOMM device/session state**, which often had to be recreated

So after restarts or disconnects, I did **not** re-pair the HC-05. Instead, I recreated the RFCOMM binding if needed.

### Challenge 3: Python environment mismatch

I installed `pyserial`, but when I tried to run the script with `sudo`, Python could not find the `serial` module.

The issue was that `pyserial` had been installed into my user Python environment, while `sudo python3` was using root’s environment.

### How I solved it

I stopped trying to combine root execution with my user-installed packages. For quick testing, I changed the permissions on `/dev/rfcomm0` and ran Python from my normal user environment.

That solved the package mismatch without forcing me to maintain two Python environments.

### Challenge 4: `/dev/rfcomm0` existed, but the test still failed

There were cases where `/dev/rfcomm0` existed, but the behavior was still inconsistent. The system sometimes looked connected at the Linux level, but the data test still did not behave reliably.

### How I solved it

Eventually I stopped depending on `/dev/rfcomm0` as the main path and moved to a **direct Bluetooth RFCOMM socket in Python** instead. That approach was cleaner for my use case because my real goal was not “make Linux create a serial device,” but rather “make Python exchange bytes with the HC-05 reliably.”

This turned out to be a better fit for the later performance experiment too, because it kept the Python program in direct control of connection setup, send timing, and receive timing.

### Challenge 5: rebooting cleared the live session state

A reboot of the Ubuntu machine removed the active RFCOMM state and I had to re-establish the connection path again. The pairing/trust relationship remained, but the live device path did not.

### How I solved it

Instead of treating this as a full reconfiguration problem, I treated it as a **session recreation problem**. After reboot:

* I verified the HC-05 was still paired/trusted in `bluetoothctl`
* I made sure the module was powered and not connected to another host
* I re-established the communication path from Python

That was much faster than repeating the full discovery and pairing process every time.

---

## Transition from Linux serial-device testing to direct Python Bluetooth testing

Once I had spent time with `/dev/rfcomm0`, it became clear that for this project, the more reliable path was to connect directly from Python over a Bluetooth RFCOMM socket.

The main advantage was that it removed one extra layer of operating-system device management and let the Python test script handle:

* connection setup
* send timing
* receive timing
* timeout handling

That was especially useful because my eventual goal was not just “open a Bluetooth serial port,” but “run a controlled telemetry and QoS experiment from Python.”

---

## A very useful hardware isolation test

To understand whether the problem was software or wiring, I did a simple but very revealing hardware experiment.

### Test 1: disconnect HC-05 RXD from the voltage divider

When I disconnected the **HC-05 pin labeled RXD** from the divider, the phone app could still turn the LED on and off.

That meant:

* the command path from the phone to the Uno did **not** depend on HC-05 RXD
* the LED control path was therefore still intact

[Image suggestion: Add a photo showing the HC-05 RXD disconnected from the voltage divider.]

### Test 2: disconnect HC-05 TXD from the Uno

When I disconnected the **HC-05 pin labeled TXD** from the Uno, the LED control stopped working entirely.

That meant:

* the phone-to-Uno command path depended on HC-05 TXD
* the Uno was receiving commands over the **HC-05 TXD → Uno RX** path

This was exactly what UART signal direction would predict, but the experiment made the architecture unmistakably clear.

[Image suggestion: Add a photo showing the HC-05 TXD disconnected from the Uno RX.]

### Engineering conclusion from the disconnection test

This told me that my current LED demo was proving only this:

**host → HC-05 → HC-05 TXD → Uno RX → LED**

It was **not** proving the reverse direction:

**Uno TX → HC-05 RXD → Bluetooth host**

That was a crucial insight, because it meant the Bluetooth LED demo was still only a **one-way control demo**, not a validated telemetry path.

## Root cause: the return path hardware was bad

The real problem turned out not to be Bluetooth pairing, Python, Ubuntu, or the Arduino sketch. The problem was physical.

I had built the voltage divider for the **Uno TX → HC-05 RXD** path by soldering two resistors together, but the connection was bad. That meant the return path from the Uno back into the HC-05 was unreliable or effectively broken.

So I rebuilt the divider using fresh resistors:

* **1 kΩ**
* **2 kΩ**

Then I measured the divider output at the junction and confirmed that it was producing approximately **3.3 V**, which is what I wanted for the signal presented to the HC-05 RX input.

[Image suggestion: Add a close-up photo of the rebuilt voltage divider circuit with the resistors and wiring.]

After rebuilding that divider and reconnecting the HC-05 RXD path, the system immediately behaved differently:

* Android terminal testing worked
* Python testing worked
* the Uno could now receive **and** transmit over Bluetooth

That was the moment the project changed from “Bluetooth LED control” into “validated bidirectional Bluetooth command path.”

## Final verification sketches

### Uno-side bidirectional echo sketch

The cleanest firmware for validation was a minimal echo-oriented sketch: if the Uno receives `1` or `0`, it updates the LED and then echoes the same byte back.

```cpp
#include <SoftwareSerial.h>

SoftwareSerial BT(10, 11); // RX, TX
const int LED = 8;

void setup() {
  BT.begin(9600);
  pinMode(LED, OUTPUT);
  digitalWrite(LED, LOW);
}

void loop() {
  if (BT.available()) {
    char c = BT.read();

    if (c == '1') {
      digitalWrite(LED, HIGH);
    } 
    else if (c == '0') {
      digitalWrite(LED, LOW);
    }

    BT.write(c);  // echo the same byte back
  }
}
```

This sketch was ideal for debugging because it tested:

* receive path
* parse path
* output control
* return path

with almost no extra logic.

## Android verification

After rebuilding the divider, I used an Android Bluetooth terminal app to test both command and terminal behavior.

That was helpful because it gave me a second host platform besides Ubuntu. It showed that the system was no longer dependent on one specific test environment, and it confirmed that the HC-05 link was behaving correctly in normal data mode.

In practical terms, this meant the project had moved beyond “it works on one machine under one condition” and toward a more credible embedded interface validation.

## Ubuntu and Python verification

After the Android-side terminal test succeeded, I verified the same path from Ubuntu using Python. The cleanest host-side path ended up being a direct Bluetooth RFCOMM socket from Python.

### Python Bluetooth socket verification script

```python
import socket
import time

HC05_ADDR = "00:14:03:05:0A:0C"
RFCOMM_CHANNEL = 1

def main():
    print("Creating Bluetooth RFCOMM socket...")
    sock = socket.socket(
        socket.AF_BLUETOOTH,
        socket.SOCK_STREAM,
        socket.BTPROTO_RFCOMM
    )
    sock.settimeout(5.0)

    try:
        print(f"Connecting to {HC05_ADDR} on channel {RFCOMM_CHANNEL}...")
        sock.connect((HC05_ADDR, RFCOMM_CHANNEL))
        print("Connected.")

        time.sleep(1.0)

        print("Sending b'1'...")
        sock.send(b'1')
        response = sock.recv(1)
        print("Response:", response)

        time.sleep(1.0)

        print("Sending b'0'...")
        sock.send(b'0')
        response = sock.recv(1)
        print("Response:", response)

    finally:
        sock.close()
        print("Socket closed.")

if __name__ == "__main__":
    main()
```

With the divider rebuilt, this script finally behaved the way it should:

* sending `b'1'` turned the LED on
* the Uno echoed `b'1'` back
* sending `b'0'` turned the LED off
* the Uno echoed `b'0'` back

At that point, I had verified the complete round-trip path on Ubuntu.

[Image suggestion: Add a screenshot of the Python script running in the terminal, showing the output with responses from the HC-05.]

## What I learned from the debugging process

### 1. A working control demo is not the same thing as a working telemetry path

One of the biggest lessons was that “the LED turns on from my phone” is not enough to conclude that the communication system is fully working.

The project only became a real telemetry platform once I proved that the Uno could send bytes back through the HC-05 reliably.

### 2. Directionality matters in UART debugging

This project reinforced a basic but essential UART principle:

* **HC-05 TXD → Uno RX** is one signal path
* **Uno TX → HC-05 RXD** is a different signal path

A system can look functional while only one of those directions is actually working.

### 3. Physical-layer issues can masquerade as software failures

I spent time thinking about:

* Python socket behavior
* Linux Bluetooth configuration
* host-side testing differences
* sketch logic

But the root cause was ultimately the voltage-divider hardware. The bad solder connection on the divider meant the reverse path was physically compromised.

That was a strong reminder that communication debugging should proceed from the physical layer upward.

### 4. Multiple host environments can help narrow the problem

Testing from both:

* Android
* Ubuntu / Python

was extremely useful. It let me separate:

* Bluetooth pairing/session issues
* host-side software issues
* embedded hardware issues

That made the debugging much faster than if I had stayed on one platform only.

### 5. Verifying the actual voltage matters

Rebuilding the divider was one thing. Measuring the divider output and confirming that the junction produced about **3.3 V** was what made it an engineering fix rather than a guess.

That measurement gave me confidence that the signal being presented to the HC-05 RX path was reasonable before reconnecting it.

### 6. Host setup is part of the embedded-system story

A major takeaway from the Ubuntu side was that the host-machine configuration matters almost as much as the microcontroller firmware when communication is involved. Pairing, trust state, RFCOMM device creation, permissions, Python interpreter environment, and session persistence all influenced progress.

That was a useful reminder that embedded communication debugging is often a **system integration problem**, not just a firmware problem.

## Why this project matters

From the outside, this project still looks like a Bluetooth LED demo. But from an engineering point of view, it became much more than that.

What I really built and debugged was a **bidirectional wireless serial interface** between a host machine and an embedded target. That is the actual capability that matters for future systems.

This same communication path can now support:

* wireless command/control
* telemetry and diagnostics
* round-trip timing experiments
* packet-loss measurement
* host-to-device benchmarking
* future QoS studies on latency, jitter, and goodput

That is why I consider this project a communication-path validation platform rather than just a beginner LED project.

## Relationship to future QoS experiments

This project is now the foundation for a follow-on performance analysis study.

Because the Uno can now echo bytes back through the HC-05, the next step is to move from simple single-character testing to **structured packet testing**. That will allow me to measure metrics such as:

* round-trip delay
* jitter
* packet loss
* goodput

That future experiment will be based on the same validated hardware path developed here.

## Suggested images to include

If I continue refining this post, the three most useful visuals would be:

1. **The schematic / breadboard image**
   This would document the actual wiring and make the TX/RX / divider paths easier to understand.

2. **A communication-path diagram**
   Something like:

   **Android / Ubuntu → HC-05 → Uno → HC-05 → Android / Ubuntu**

   with labels showing:

   * HC-05 TXD → Uno RX
   * Uno TX → divider → HC-05 RXD

3. **An Ubuntu host setup screenshot**
   A screenshot of the `bluetoothctl` output showing:

   * the HC-05 device name
   * paired/trusted state
   * Serial Port UUID

That would make the Linux configuration part of the story much easier to follow.

Note: Images will be added in future revisions to illustrate the wiring, communication paths, and Ubuntu setup for better clarity.

## Final reflection

This project was a good example of how a simple prototype can expose real embedded-systems issues.

The final visible output was only an LED, but the engineering value came from validating the complete path between:

* host software
* Bluetooth transport
* Ubuntu host configuration
* UART wiring
* microcontroller firmware
* hardware output
* return telemetry

The most important takeaway was not that Bluetooth worked. It was that **one-way success can hide a broken return path**, and that careful, layered debugging is what turns a demo into a reliable system.

## References

* Bluetooth SIG. *Serial Port Profile 1.1*.
* Arduino. *UNO R3 documentation*.
* Arduino. *SoftwareSerial example*.
* BlueZ / Debian Manpages. *bluetoothctl(1)*.
* Ubuntu Manpages. *rfcomm(1)*.

[1]: https://www.bluetooth.com/specifications/specs/serial-port-profile-1-1/ "Serial Port Profile | Bluetooth® Technology Website"
[2]: https://docs.arduino.cc/hardware/uno-rev3 "docs.arduino.cc"
[3]: https://manpages.debian.org/unstable/bluez/bluetoothctl.1.en.html "bluetoothctl(1) — bluez — Debian unstable — Debian Manpages"
[4]: https://manpages.ubuntu.com/manpages/jammy/man1/rfcomm.1.html "Ubuntu Manpage: rfcomm - RFCOMM configuration utility"