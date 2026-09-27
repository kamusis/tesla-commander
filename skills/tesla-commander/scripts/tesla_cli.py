#!/usr/bin/env python3
"""
Tesla Commander CLI
Comprehensive vehicle control, state inspection, telemetry streaming,
and AI-powered navigation for Tesla via Tessie.
"""

import sys
import os
import argparse
import json
import subprocess
from typing import Optional

from tesla_client import TessieClient
from geo_resolver import GeoResolver

def print_table(rows, headers):
    """Simple terminal table formatter."""
    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, val in enumerate(row):
            col_widths[i] = max(col_widths[i], len(str(val)))

    header_line = " | ".join(h.ljust(col_widths[i]) for i, h in enumerate(headers))
    sep_line = "-+-".join("-" * col_widths[i] for i in range(len(headers)))
    print(header_line)
    print(sep_line)
    for row in rows:
        print(" | ".join(str(val).ljust(col_widths[i]) for i, val in enumerate(row)))

def cmd_status(args, client: TessieClient):
    """Show comprehensive vehicle status summary."""
    vin = client.resolve_vin(args.vin)
    state = client.get_state(vin)

    vs = state.get("vehicle_state", {})
    cs = state.get("charge_state", {})
    cls = state.get("climate_state", {})
    drive = state.get("drive_state", {})
    cfg = state.get("vehicle_config", {})

    display_name = vs.get("vehicle_name") or state.get("display_name") or "Tesla"
    model = cfg.get("model") or "Model Y"
    firmware = vs.get("car_version", "N/A")
    online = state.get("state", "unknown")

    # Battery & Charging
    battery_level = cs.get("battery_level", "N/A")
    battery_range = round(cs.get("battery_range", 0) * 1.60934, 1)  # miles to km
    charge_limit = cs.get("charge_limit_soc", "N/A")
    charging_state = cs.get("charging_state", "Disconnected")

    # Climate
    is_climate_on = cls.get("is_climate_on", False)
    inside_temp = cls.get("inside_temp")
    outside_temp = cls.get("outside_temp")
    driver_temp = cls.get("driver_temp_setting")

    # Locking & Security
    locked = vs.get("locked", False)
    sentry = vs.get("sentry_mode", False)
    valet = vs.get("valet_mode", False)

    # Tire Pressure (Bar)
    tpms_fl = vs.get("tpms_pressure_fl", "N/A")
    tpms_fr = vs.get("tpms_pressure_fr", "N/A")
    tpms_rl = vs.get("tpms_pressure_rl", "N/A")
    tpms_rr = vs.get("tpms_pressure_rr", "N/A")

    # Odometer
    odometer_km = round(vs.get("odometer", 0) * 1.60934, 1)

    if args.json:
        print(json.dumps(state, indent=2))
        return

    print(f"\n=======================================================")
    print(f"  {display_name} ({model}) - Status Summary")
    print(f"  VIN: {vin} | Status: {online.upper()} | FW: {firmware}")
    print(f"=======================================================\n")

    print("[Battery & Energy]")
    print(f"  Battery Level : {battery_level}% (Limit: {charge_limit}%)")
    print(f"  Rated Range   : {battery_range} km")
    print(f"  Charging State: {charging_state}")
    if charging_state == "Charging":
        print(f"  Charge Rate   : {cs.get('charger_power', 0)} kW ({cs.get('charge_current_request', 0)} A)")
        print(f"  Time to Full  : {cs.get('time_to_full_charge', 0)} hours")

    print("\n[Climate & Cabin]")
    print(f"  HVAC State    : {'ON' if is_climate_on else 'OFF'}")
    print(f"  Inside Temp   : {inside_temp}°C" if inside_temp is not None else "  Inside Temp   : N/A")
    print(f"  Outside Temp  : {outside_temp}°C" if outside_temp is not None else "  Outside Temp  : N/A")
    print(f"  Target Temp   : {driver_temp}°C" if driver_temp is not None else "  Target Temp   : N/A")

    print("\n[Vehicle Controls & Security]")
    print(f"  Doors         : {'LOCKED' if locked else 'UNLOCKED'}")
    print(f"  Sentry Mode   : {'ACTIVE' if sentry else 'OFF'}")
    print(f"  Total Mileage : {odometer_km:,} km")

    print("\n[Tire Pressure (Bar)]")
    print(f"  Front Left : {tpms_fl} bar  |  Front Right : {tpms_fr} bar")
    print(f"  Rear Left  : {tpms_rl} bar  |  Rear Right  : {tpms_rr} bar")
    print()

def cmd_location(args, client: TessieClient):
    """Show current vehicle GPS location and street address."""
    vin = client.resolve_vin(args.vin)
    loc = client.get_location(vin)
    if args.json:
        print(json.dumps(loc, indent=2))
        return
    print(f"Vehicle Location:")
    print(f"  Latitude  : {loc.get('latitude')}")
    print(f"  Longitude : {loc.get('longitude')}")
    print(f"  Address   : {loc.get('address')}")
    if loc.get("saved_location"):
        print(f"  Saved Spot: {loc.get('saved_location')}")

def cmd_control(args, client: TessieClient):
    """Execute physical or remote vehicle control commands."""
    vin = client.resolve_vin(args.vin)
    action = args.action.lower()

    # Safety Guardrails for critical physical actions
    critical_actions = {
        "unlock": "Unlock vehicle doors",
        "frunk": "Pop open front trunk (Frunk)",
        "trunk": "Open rear trunk",
        "open_tonneau": "Open tonneau cover"
    }

    if action in critical_actions and not args.force:
        print(f"[GUARDRAIL WARNING] You requested: {critical_actions[action]}.")
        print(f"Physical action on vehicle {vin} requires confirmation.")
        print(f"Re-run with --force to execute.")
        sys.exit(1)

    # Action mappings
    action_map = {
        "honk": ("honk", None),
        "flash": ("flash_lights", None),
        "lock": ("lock", None),
        "unlock": ("unlock", None),
        "frunk": ("front_trunk", None),
        "trunk": ("rear_trunk", None),
        "vent": ("vent_windows", None),
        "close_windows": ("close_windows", None),
        "sentry_on": ("enable_sentry", None),
        "sentry_off": ("disable_sentry", None),
        "wake": ("wake", None)
    }

    if action not in action_map:
        print(f"Error: Unknown control action '{action}'. Supported: {', '.join(action_map.keys())}")
        sys.exit(1)

    api_action, params = action_map[action]
    if api_action == "wake":
        res = client.wake(vin)
    else:
        res = client.send_command(api_action, vin, params)

    print(f"Command '{action}' executed: {json.dumps(res)}")

def cmd_climate(args, client: TessieClient):
    """Climate control actions."""
    vin = client.resolve_vin(args.vin)
    sub = args.subcommand.lower()

    if sub == "on":
        res = client.set_climate("start_climate", vin)
    elif sub == "off":
        res = client.set_climate("stop_climate", vin)
    elif sub == "temp":
        if args.value is None:
            print("Error: Missing temperature value. Usage: climate temp 22.5")
            sys.exit(1)
        res = client.set_climate("set_temperature", vin, {"temperature": float(args.value)})
    elif sub == "seat":
        if args.value is None or args.level is None:
            print("Error: Missing seat position or level. Usage: climate seat driver 2 (0=off, 1-3)")
            sys.exit(1)
        seat_map = {
            "driver": 0, "front_left": 0,
            "passenger": 1, "front_right": 1,
            "rear_left": 2, "rear_center": 4, "rear_right": 5
        }
        pos = seat_map.get(args.value.lower(), 0)
        res = client.set_climate("set_seat_heating", vin, {"seat": pos, "level": int(args.level)})
    elif sub == "defrost":
        if args.value == "on":
            res = client.set_climate("start_defrost", vin)
        else:
            res = client.set_climate("stop_defrost", vin)
    elif sub == "steering":
        if args.value == "on":
            res = client.set_climate("start_steering_wheel_heater", vin)
        else:
            res = client.set_climate("stop_steering_wheel_heater", vin)
    else:
        print(f"Unknown climate subcommand '{sub}'. Supported: on, off, temp, seat, defrost, steering")
        sys.exit(1)

    print(f"Climate command executed: {json.dumps(res)}")

def cmd_charge(args, client: TessieClient):
    """Charging control actions."""
    vin = client.resolve_vin(args.vin)
    sub = args.subcommand.lower()

    if sub == "status":
        res = client.get_battery(vin)
        print(json.dumps(res, indent=2))
        return
    elif sub == "start":
        res = client.set_charging("start_charging", vin)
    elif sub == "stop":
        res = client.set_charging("stop_charging", vin)
    elif sub == "limit":
        if args.value is None:
            print("Error: Missing charge limit percentage. Usage: charge limit 80")
            sys.exit(1)
        res = client.set_charging("set_charge_limit", vin, {"limit": int(args.value)})
    elif sub == "amps":
        if args.value is None:
            print("Error: Missing charging current amps. Usage: charge amps 16")
            sys.exit(1)
        res = client.set_charging("set_charging_amps", vin, {"amps": int(args.value)})
    elif sub == "open":
        res = client.set_charging("open_charge_port", vin)
    elif sub == "close":
        res = client.set_charging("close_charge_port", vin)
    else:
        print(f"Unknown charge subcommand '{sub}'. Supported: status, start, stop, limit, amps, open, close")
        sys.exit(1)

    print(f"Charging command executed: {json.dumps(res)}")

def cmd_nav(args, client: TessieClient):
    """
    AI-powered Destination Search & Direct Vehicle Routing.
    Resolves natural language queries to exact GPS coordinates and sends to Tesla.
    """
    destination_query = " ".join(args.destination).strip()
    if not destination_query:
        print("Error: Please provide a destination query. Example: nav 名古屋駅高島屋")
        sys.exit(1)

    vin = client.resolve_vin(args.vin)
    print(f"[Nav] Analyzing destination: \"{destination_query}\"...")

    # Step 1: Fetch current location for contextual relative searches
    current_loc = None
    loc_desc = None
    try:
        raw_loc = client.get_location(vin)
        lat = raw_loc.get("latitude")
        lng = raw_loc.get("longitude")
        if lat and lng:
            current_loc = (lat, lng)
            loc_desc = raw_loc.get("address") or raw_loc.get("saved_location")
            print(f"[Nav] Vehicle current location: {current_loc[0]}, {current_loc[1]} ({loc_desc})")
    except Exception as e:
        print(f"[Nav] Note: Could not fetch vehicle current location ({e}), proceeding with global query.")

    # Step 2: Resolve coordinates using Dual-Engine GeoResolver
    resolver = GeoResolver()
    res = resolver.resolve(destination_query, current_loc, loc_desc)

    name = res.get("name")
    address = res.get("address")
    lat = res.get("lat")
    lng = res.get("lng")
    engine = res.get("engine", "unknown")

    candidates = res.get("candidates", [])
    if len(candidates) > 1:
        print(f"\n[Nav] Found {len(candidates)} matching candidate(s) (auto-selected closest #1):")
        for idx, c in enumerate(candidates):
            mark = "=>" if idx == 0 else "  "
            dist_str = f" [距车 {c.get('distance_km')} km]" if c.get('distance_km') is not None else ""
            print(f"  {mark} [{idx+1}] {c.get('name')}{dist_str} - {c.get('address')}")

    print(f"\n[Nav] Resolved Destination:")
    print(f"  Name      : {name}")
    print(f"  Address   : {address}")
    print(f"  Location  : {lat}, {lng}")
    print(f"  Engine    : {engine}")

    if res.get("is_fallback") or engine == "openstreetmap_nominatim":
        print("\n" + "!" * 70)
        print("  [CAUTION / 提示] 当前已触发【OpenStreetMap 兜底引擎】！")
        print(f"  - 触发原因 : {res.get('fallback_reason', '主引擎异常')}")
        print("  - 精度风险 : 开源地图缺乏空间拓扑推理，尤其对连锁分店最近距离计算、")
        print("               中日文口语转换精度有限，解析出的目的地可能存在偏差！")
        print("  - 行动建议 : 请上车后务必在特斯拉中控屏幕核对目的地名称与路线。")
        print("!" * 70)

    # Step 3: Push exact coordinates directly to Tessie Share API with locale=ja-JP
    val_to_send = f"{lat},{lng}"
    print(f"\n[Nav] Sending coordinates to vehicle {vin} with locale=ja-JP...")
    share_res = client.share_navigation(val_to_send, vin=vin, locale="ja-JP")

    if share_res.get("result"):
        print(f"[Nav] SUCCESS! Destination pushed to in-car display. Navigation route initiated.")
    else:
        print(f"[Nav] Response: {json.dumps(share_res)}")

def cmd_stream(args, client: TessieClient):
    """Stream real-time Fleet Telemetry using Node.js WebSocket client."""
    vin = client.resolve_vin(args.vin)
    script_path = os.path.join(os.path.dirname(__file__), "telemetry_stream.js")

    node_cmd = ["node", script_path, "--vin", vin, "--duration", str(args.duration)]
    if args.json:
        node_cmd.append("--json")

    try:
        subprocess.run(node_cmd, check=True)
    except KeyboardInterrupt:
        print("\n[Telemetry] Streaming terminated by user.")
    except Exception as e:
        print(f"[Telemetry] Streaming error: {e}")

def cmd_analytics(args, client: TessieClient):
    """View driving and charging history."""
    vin = client.resolve_vin(args.vin)
    sub = args.subcommand.lower()

    if sub == "drives":
        raw_drives = client.get_drives(vin, limit=args.limit)
        drives = []
        for i, d in enumerate(raw_drives):
            drives.append(d)
            if i + 1 < len(raw_drives):
                prev = raw_drives[i + 1]
                curr_start = d.get("starting_odometer") or 0.0
                prev_end = prev.get("ending_odometer") or 0.0
                gap = curr_start - prev_end
                if curr_start > 0 and prev_end > 0 and 0.2 <= gap < 1000.0:
                    prev_ended_at = prev.get("ended_at") or 0
                    curr_started_at = d.get("started_at") or 0
                    dist_km = round(gap * 1.60934, 1)
                    duration_sec = max(180, int((dist_km / 25.0) * 3600.0))
                    syn_end = curr_started_at
                    syn_start = max(prev_ended_at, syn_end - duration_sec)
                    drives.append({
                        "id": f"-{abs(d.get('id', 0)) * 10 + 9}",
                        "is_synthetic": True,
                        "odometer_distance": gap,
                        "duration_minutes": round((syn_end - syn_start) / 60.0, 1),
                        "energy_used": 0.0,
                        "starting_location": prev.get("ending_saved_location") or prev.get("ending_location") or "N/A",
                        "ending_location": d.get("starting_saved_location") or d.get("starting_location") or "N/A",
                        "started_at": syn_start,
                        "ended_at": syn_end
                    })
        if args.json:
            print(json.dumps(drives, indent=2))
            return
        rows = []
        for d in drives:
            dist = round((d.get("odometer_distance") or d.get("distance") or 0) * 1.60934, 1)  # km
            energy = round(d.get("energy_used") or 0, 2)
            if "duration_minutes" in d:
                duration = round(d["duration_minutes"], 1)
            elif d.get("started_at") and d.get("ended_at"):
                duration = round((d["ended_at"] - d["started_at"]) / 60.0, 1)
            else:
                duration = 0.0
            start_addr = (d.get("starting_saved_location") or d.get("starting_location") or d.get("starting_address") or "N/A").split(",")[0]
            end_addr = (d.get("ending_saved_location") or d.get("ending_location") or d.get("ending_address") or "N/A").split(",")[0]
            did = str(d.get("id"))
            energy_str = f"{energy} kWh" if not d.get("is_synthetic") else "离线推算"
            rows.append([did, f"{dist} km", f"{duration}m", energy_str, start_addr, end_addr])
        print_table(rows, ["ID", "Distance", "Duration", "Energy", "From", "To"])

    elif sub == "charges":
        charges = client.get_charges(vin, limit=args.limit)
        if args.json:
            print(json.dumps(charges, indent=2))
            return
        rows = []
        for c in charges:
            energy = round(c.get("energy_added", 0), 2)
            cost = c.get("cost", "N/A")
            addr = (c.get("address") or "N/A").split(",")[0]
            rows.append([c.get("id"), f"{energy} kWh", cost, addr])
        print_table(rows, ["ID", "Added", "Cost", "Location"])

    elif sub == "battery":
        health = client.get_battery_health()
        print(json.dumps(health, indent=2))

def main():
    parser = argparse.ArgumentParser(description="Tesla Commander - Advanced Tessie & Telemetry CLI")
    parser.add_argument("--vin", help="Target vehicle VIN or display name (default: auto-detect active vehicle)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # status
    p_status = subparsers.add_parser("status", help="Get comprehensive vehicle status")
    p_status.add_argument("--json", action="store_true", help="Output raw JSON")

    # location
    p_loc = subparsers.add_parser("location", help="Get current vehicle GPS coordinates and address")
    p_loc.add_argument("--json", action="store_true", help="Output raw JSON")

    # control
    p_ctrl = subparsers.add_parser("control", help="Physical & remote vehicle controls")
    p_ctrl.add_argument("action", help="honk, flash, lock, unlock, frunk, trunk, vent, close_windows, sentry_on, sentry_off, wake")
    p_ctrl.add_argument("--force", action="store_true", help="Bypass safety guardrail for unlock/frunk/trunk")

    # climate
    p_clim = subparsers.add_parser("climate", help="Cabin climate & heating control")
    p_clim.add_argument("subcommand", help="on, off, temp, seat, defrost, steering")
    p_clim.add_argument("value", nargs="?", help="Temperature (C) / seat name / on/off")
    p_clim.add_argument("level", nargs="?", help="Seat heating level (0-3)")

    # charge
    p_chg = subparsers.add_parser("charge", help="Charging management")
    p_chg.add_argument("subcommand", help="status, start, stop, limit, amps, open, close")
    p_chg.add_argument("value", nargs="?", help="Limit % or Amps value")

    # nav
    p_nav = subparsers.add_parser("nav", help="Natural language destination search & vehicle routing")
    p_nav.add_argument("destination", nargs="+", help="Destination in Chinese, Japanese, or English")

    # telemetry stream
    p_str = subparsers.add_parser("stream", help="Stream live vehicle Fleet Telemetry")
    p_str.add_argument("--duration", type=int, default=15, help="Duration in seconds (default: 15)")
    p_str.add_argument("--json", action="store_true", help="Output raw JSON stream")

    # analytics
    p_ana = subparsers.add_parser("analytics", help="Driving & charging analytics")
    p_ana.add_argument("subcommand", help="drives, charges, battery")
    p_ana.add_argument("--limit", type=int, default=5, help="Number of records to show")
    p_ana.add_argument("--json", action="store_true", help="Output raw JSON")

    args = parser.parse_args()
    client = TessieClient()

    if args.command == "status":
        cmd_status(args, client)
    elif args.command == "location":
        cmd_location(args, client)
    elif args.command == "control":
        cmd_control(args, client)
    elif args.command == "climate":
        cmd_climate(args, client)
    elif args.command == "charge":
        cmd_charge(args, client)
    elif args.command == "nav":
        cmd_nav(args, client)
    elif args.command == "stream":
        cmd_stream(args, client)
    elif args.command == "analytics":
        cmd_analytics(args, client)

if __name__ == "__main__":
    main()
