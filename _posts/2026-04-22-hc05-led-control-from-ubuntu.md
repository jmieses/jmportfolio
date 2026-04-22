---
layout: post
title: "Bidirectional Bluetooth Command Path Validation with HC-05 and Elegoo Uno R3"
date: 2026-04-21
categories:
  - embedded-systems
  - communications
  - arduino
tags:
  - hc-05
  - bluetooth
  - uart
  - arduino
  - ubuntu
  - python
  - debugging
  - telemetry
excerpt: "An engineering-focused build log on validating a bidirectional Bluetooth command path using an HC-05 and an Elegoo Uno R3, including serial-interface debugging, Linux host integration, and the hardware root cause that blocked reverse telemetry."
---

# Bidirectional Bluetooth Command Path Validation with HC-05 and Elegoo Uno R3

This project started as a simple Bluetooth LED demo, but it quickly became a more interesting engineering problem: **how to validate a full bidirectional command-and-telemetry path between a host machine and an embedded target**.

At a high level, the goal was to send commands wirelessly from a host device to an **Elegoo Uno R3** through an **HC-05 Bluetooth module**, drive a visible hardware output, and then verify that the microcontroller could also send data back over the same Bluetooth link. That last part ended up being the critical difference between a one-way control demo and a real telemetry foundation.

What looked like a basic “turn an LED on over Bluetooth” exercise ultimately became a focused debugging effort involving:

- UART signal direction and interface ownership
- Bluetooth Serial Port Profile behavior
- Linux host communication
- Arduino software architecture
- physical-layer debugging on the return path
- voltage-divider integrity and signal validation

From an engineering perspective, the final result was more valuable than the original demo because it validated the complete communication chain needed for future **QoS / telemetry experiments**.

## Why I chose the HC-05

I chose the **HC-05** because it is one of the most approachable modules for learning Bluetooth communication at the embedded-systems level. The key advantage is that it behaves like a **serial bridge**: the Bluetooth side presents a Serial Port Profile (SPP) connection, and the embedded side presents a UART interface. In other words, it lets a wireless link look like an emulated serial cable over RFCOMM.

That made it a good fit for what I wanted to learn:

- how Bluetooth commands map into UART bytes
- how to debug a communication path layer by layer
- how to verify both control and return telemetry
- how to prepare a simple embedded platform for later performance benchmarking

I intentionally chose something simpler than BLE or Wi-Fi because I wanted the communication model to stay visible rather than abstracted away.

## Project objective

The immediate functional objective was straightforward:

- send `'1'` over Bluetooth to turn an LED on
- send `'0'` over Bluetooth to turn an LED off

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

- Elegoo Uno R3
- HC-05 Bluetooth module
- LED
- current-limiting resistor for the LED
- resistor divider on the Uno TX → HC-05 RX path
- breadboard and jumper wires

### Software / host environments

- Arduino IDE
- Android Bluetooth terminal app
- Ubuntu 20.04
- Python 3.11
- Python RFCOMM socket testing

## System architecture

At a functional level, the system looks like this:

**Host terminal / Python script → Bluetooth SPP link → HC-05 → UART → Uno firmware → LED output**

And for the return path:

**Uno firmware → UART → HC-05 → Bluetooth SPP link → host terminal / Python script**

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

One of the first practical lessons in the project was that on an Arduino Uno-class board, the main hardware UART is on **digital pins 0 (RX) and 1 (TX)**, and that UART is also connected to the onboard USB interface. That creates a conflict if I want to use the USB serial monitor for debugging while also using Bluetooth on the same serial path.

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

## Transition from control demo to telemetry validation

Once I had one-way LED control working, I started trying to verify the Uno from an Ubuntu machine using Python. My first thought was to treat the HC-05 as a serial device from Linux and then use Python to send and receive bytes.

The forward path appeared to work:

* Python connected to the HC-05
* Python sent `b'1'`
* the LED turned on

But the return path failed:

* Python waited for a reply
* no reply came back
* the socket timed out

That was the first major clue that the system might only be working in one direction.

## A very useful hardware isolation test

To understand whether the problem was software or wiring, I did a simple but very revealing hardware experiment.

### Test 1: disconnect HC-05 RXD from the voltage divider

When I disconnected the **HC-05 pin labeled RXD** from the divider, the phone app could still turn the LED on and off.

That meant:

* the command path from the phone to the Uno did **not** depend on HC-05 RXD
* the LED control path was therefore still intact

### Test 2: disconnect HC-05 TXD from the Uno

When I disconnected the **HC-05 pin labeled TXD** from the Uno, the LED control stopped working entirely.

That meant:

* the phone-to-Uno command path depended on HC-05 TXD
* the Uno was receiving commands over the **HC-05 TXD → Uno RX** path

This was exactly what UART signal direction would predict, but the experiment made the architecture unmistakably clear.

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

After the Android-side terminal test succeeded, I verified the same path from Ubuntu using Python. I initially experimented with Linux serial-device approaches, but the cleanest host-side path ended up being a direct Bluetooth RFCOMM socket from Python.

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

If I continue refining this post, the two most useful visuals would be:

1. **The schematic / breadboard image**
   This would document the actual wiring and make the TX/RX / divider paths easier to understand.

2. **A communication-path diagram**
   Something like:

   **Android / Ubuntu → HC-05 → Uno → HC-05 → Android / Ubuntu**

   with labels showing:

   * HC-05 TXD → Uno RX
   * Uno TX → divider → HC-05 RXD

If I add those later, they will make the debugging story much easier to follow visually.

## Final reflection

This project was a good example of how a simple prototype can expose real embedded-systems issues.

The final visible output was only an LED, but the engineering value came from validating the complete path between:

* host software
* Bluetooth transport
* UART wiring
* microcontroller firmware
* hardware output
* return telemetry

The most important takeaway was not that Bluetooth worked. It was that **one-way success can hide a broken return path**, and that careful, layered debugging is what turns a demo into a reliable system.

## References

* Bluetooth SIG, *Serial Port Profile 1.1*
  [https://www.bluetooth.com/specifications/specs/serial-port-profile-1-1/](https://www.bluetooth.com/specifications/specs/serial-port-profile-1-1/)

* Bluetooth SIG, *Core Specification Acronyms and Abbreviations*
  [https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/architecture%2C-change-history%2C-and-conventions/acronyms---abbreviations.html](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/architecture%2C-change-history%2C-and-conventions/acronyms---abbreviations.html)

* Arduino, *Arduino UNO Rev3 documentation*
  [https://docs.arduino.cc/hardware/uno-rev3](https://docs.arduino.cc/hardware/uno-rev3)

* Arduino, *Arduino UNO Rev3 with Long Pins*
  [https://docs.arduino.cc/retired/boards/arduino-uno-rev3-with-long-pins/](https://docs.arduino.cc/retired/boards/arduino-uno-rev3-with-long-pins/)

* Arduino, *SoftwareSerial example / adding more serial ports*
  [https://docs.arduino.cc/tutorials/communication/SoftwareSerialExample](https://docs.arduino.cc/tutorials/communication/SoftwareSerialExample)