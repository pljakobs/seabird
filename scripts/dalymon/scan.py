import asyncio
from bleak import BleakScanner

async def scan_for_bms():
    print("Scanning for Bluetooth devices...")
    devices = await BleakScanner.discover()
    for d in devices:
        # Daly devices often show as "DL-BMS" or a serial number
        if d.name:
            print(f"Device found: {d.name} | Address: {d.address}")

asyncio.run(scan_for_bms())
