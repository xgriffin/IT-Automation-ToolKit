# Wifi or network connection problems

## Symptoms
- Device shows "no internet" or won't connect to wifi
- Handheld scanners or tablets drop connection
- Slow network

## Resolution (single device)
1. Turn wifi off and on, or forget the network and reconnect.
2. Restart the device.
3. Confirm the device has an IP address (`ipconfig` on Windows). A 169.254.x.x address means DHCP failed.

## Resolution (many devices / whole area)
1. Check the access point status in the wireless controller.
2. Check the switch port and PoE for that access point in the IDF.
3. Check the DHCP scope for exhausted leases.
4. Escalate to the network team if the uplink is down.
