HOME NETWORK & SECURITY SYSTEM - INSTALLATION SPECIFICATION
===============================================================

Property: [REDACTED — street address intentionally omitted from version control]
Home: Single-story new construction, 2,264 SF, 4 bed / 3 bath, 2-car garage
Wiring Center: Office (middle room, left side of house)
Date: April 2026
Requirements: All local storage, zero cloud, zero subscriptions, no Chinese-manufactured hardware


1. EQUIPMENT & SHOPPING LIST
---------------------------------------------------------------
All US-headquartered companies: Ubiquiti (New York, NY), Netgate (Austin, TX),
Eaton/Tripp Lite (Dublin, OH), Western Digital (San Jose, CA)

Item                              | Details                                    | Price
----------------------------------|--------------------------------------------|-------
Netgate 2100                      | pfSense firewall, US-made (Austin, TX)     | $349
Ubiquiti USW-Lite-16-PoE          | 16-port managed switch, 8x PoE (45W)      | $199
Ubiquiti UNVR Instant             | NVR + 6-port PoE switch, 1x 3.5" HDD bay  | $199
Ubiquiti G5 Bullet x6             | 2K (4MP) PoE outdoor cameras, AI detection | $774
Ubiquiti G4 Doorbell Pro PoE Kit  | Dual camera + PoE chime included           | $379
WD Purple 4TB (WD43PURZ)          | Surveillance-rated HDD for UNVR Instant    | $85
Tripp Lite SRW9U                  | 9U wall-mount enclosed rack, 19", lockable | $225
24-Port Cat6a Patch Panel (1U)    | Keystone-style, tool-less or 110 punch     | $35
1U Vented Rack Shelf x2           | For UNVR Instant and modem (non-rack)      | $40
1U Rack-Mount Power Strip         | Surge-protected, 6-8 outlets               | $25
Cat6a Bulk Cable (1000ft)         | Solid copper, UTP, CMR rated               | $180
Cat6a Keystone Jacks + Wall Plates| For room drops and camera locations         | $50
----------------------------------|--------------------------------------------|-------
TOTAL (Hardware)                  | Zero subscriptions, zero cloud             | $2,540

Note: Add labor costs for low-voltage technician cable runs
(typically $150-250 per drop post-construction).


2. NETWORK SIGNAL PATH
---------------------------------------------------------------
Comcast NID (exterior)
  → RG6 Coax →
Comcast Modem (bridge mode)
  → Ethernet →
Netgate 2100 (pfSense firewall)
  → Ethernet →
USW-Lite-16-PoE (main switch)
  → Ethernet →
  ├── UNVR Instant → 6x G5 Bullet cameras (PoE)
  ├── G4 Doorbell Pro (PoE)
  ├── Office workstation
  └── WiFi AP / other devices


3. VLAN ARCHITECTURE (pfSense)
---------------------------------------------------------------
Camera VLAN has ZERO internet access.

VLAN   | Name                | Purpose / Rules
-------|---------------------|------------------------------------------
VLAN 1 | Management/Personal | Office workstation, personal devices. Full internet.
VLAN 10| Security Cameras    | All G5 Bullets + Doorbell + UNVR. NO internet. Local only.
VLAN 20| IoT Devices         | Smart home devices, streaming. Internet, isolated from VLAN 1.
VLAN 30| Guest WiFi          | Guest wireless. Internet only, no LAN access.


4. CAMERA PLACEMENT (360° COVERAGE)
---------------------------------------------------------------
7 cameras provide overlapping 360° coverage.
All cameras are PoE (powered + connected via single Cat6a cable).

FRONT COVERAGE (4 devices):
  1. Doorbell (G4 Doorbell Pro) — Porch, walkway, visitor ID (155° diagonal FOV)
  2. Left Front (G5 Bullet) — Driveway, garage doors, left side yard
  3. Right Front (G5 Bullet) — Right side yard, right front approach
  4. Front Center (G5 Bullet) — Full front yard, street approach, fills gap between corners

REAR COVERAGE (3 devices):
  5. Left Rear (G5 Bullet) — Left side yard continuation, left backyard
  6. Right Rear (G5 Bullet) — Right side yard continuation, right backyard
  7. Rear Center (G5 Bullet) — Lanai entry, full backyard depth

#  | Location         | Device              | Mount Position          | Cable Run
---|------------------|---------------------|-------------------------|---------------------------
1  | Front Door       | G4 Doorbell Pro PoE | Door frame, 48" height  | Cat6a to USW-Lite-16-PoE
2  | Left Front Corner| G5 Bullet           | Eave/soffit, garage side| Cat6a to UNVR Instant
3  | Right Front Corner| G5 Bullet          | Eave/soffit, right side | Cat6a to UNVR Instant
4  | Front Center     | G5 Bullet           | Eave above garage/entry | Cat6a to UNVR Instant
5  | Left Rear Corner | G5 Bullet           | Eave/soffit, left rear  | Cat6a to UNVR Instant
6  | Right Rear Corner| G5 Bullet           | Eave/soffit, right rear | Cat6a to UNVR Instant
7  | Rear Center      | G5 Bullet           | Eave above lanai        | Cat6a to UNVR Instant


5. CABLE RUN SCHEDULE
---------------------------------------------------------------
All runs originate from the office patch panel.
Runs 1-9 are REQUIRED. Runs 10-14 are OPTIONAL but recommended.

Cable Spec: Cat6a, solid copper, UTP (unshielded), CMR (riser) rated
Performance: 500 MHz bandwidth, 10 Gbps to 100 meters
Coax: Run 1 only — RG6 from Comcast NID to office

#   | Run Description              | Cable Type | Termination A | Termination B
----|------------------------------|------------|---------------|-------------------------
1   | Comcast NID to Office        | RG6 Coax   | Exterior NID  | Modem in rack
2   | Office Workstation           | Cat6a      | Patch panel   | Wall plate at desk
3   | Front Door (Doorbell)        | Cat6a      | Patch panel   | Exterior junction box
4   | Camera: Left Front           | Cat6a      | Patch panel   | Exterior weatherproof box
5   | Camera: Right Front          | Cat6a      | Patch panel   | Exterior weatherproof box
6   | Camera: Front Center         | Cat6a      | Patch panel   | Exterior weatherproof box
7   | Camera: Left Rear            | Cat6a      | Patch panel   | Exterior weatherproof box
8   | Camera: Right Rear           | Cat6a      | Patch panel   | Exterior weatherproof box
9   | Camera: Rear Center          | Cat6a      | Patch panel   | Exterior weatherproof box
10  | Great Room TV (optional)     | Cat6a      | Patch panel   | Wall plate behind TV
11  | Lanai/Outdoor TV (optional)  | Cat6a      | Patch panel   | Weatherproof wall plate
12  | Master Bedroom (optional)    | Cat6a      | Patch panel   | Wall plate
13  | Back Suite/Bed 4 (optional)  | Cat6a      | Patch panel   | Wall plate
14  | WiFi AP location (optional)  | Cat6a      | Patch panel   | Ceiling mount


6. RACK LAYOUT (9U WALL-MOUNT)
---------------------------------------------------------------
Tripp Lite SRW9U mounted in office.

Position | Device                      | Notes
---------|-----------------------------|--------------------------------------
1U (top) | Patch Panel (24-port Cat6a) | All cable runs terminate here
2U       | Netgate 2100 (pfSense)      | Firewall/router, connects to modem
3U       | USW-Lite-16-PoE (on shelf)  | Main switch, powers doorbell + PoE
4U       | UNVR Instant (on shelf)     | NVR for cameras, powers 6x G5 Bullets
5U       | Comcast Modem (on shelf)    | Bridge mode, coax in from NID
6U       | 1U Rack Power Strip         | Surge-protected power for all devices
7U-9U    | Empty (future expansion)    | UPS, additional switch, WiFi AP, etc.


7. NOTES FOR TECHNICIAN
---------------------------------------------------------------
1.  All ethernet runs are Cat6a. Do not substitute Cat6 or Cat5e.
    The cable cost difference is minimal compared to labor, and
    re-pulling later is not an option.

2.  All camera cable runs terminate at exterior weatherproof junction
    boxes mounted at eave/soffit height. Cameras mount directly above
    or adjacent.

3.  The doorbell run exits the wall near the front door frame at
    approximately 48 inches height. The G4 Doorbell Pro PoE requires
    a single Cat6a drop (no separate power wiring).

4.  Label every cable at both ends with the run number from the Cable
    Run Schedule (Section 5). Use printed labels, not handwritten.

5.  The coax run (Run 1) is RG6 from the exterior Comcast NID to the
    office rack location. Comcast will install the NID separately.

6.  Terminate all Cat6a runs to Cat6a-rated keystone jacks at wall
    plates (room side) and Cat6a patch panel (rack side). Do not use
    Cat6 keystones.

7.  Seal all exterior wall penetrations with waterproof silicone or
    duct seal putty. Florida humidity and rain require proper
    weatherproofing.

8.  Test every run with a cable tester after termination. Verify
    continuity and proper pin-out (T568B standard) before closing
    any walls.

9.  Leave 12-18 inches of service loop at each termination point for
    future re-termination if needed.

10. Optional runs 10-14 should be completed during this visit if
    budget allows. The incremental cable cost is minimal versus
    scheduling a return trip.

===============================================================
All equipment zero-subscription, local-storage-only, US-company sourced.
No Chinese-manufactured hardware. Prepared April 2026.
====================================
