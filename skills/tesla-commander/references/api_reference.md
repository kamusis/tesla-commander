# Tessie REST API Complete Reference

Base URL: `https://api.tessie.com`
Authentication Header: `Authorization: Bearer $TESSIE_ACCESS_TOKEN`
URL Query Authentication: `?access_token=$TESSIE_ACCESS_TOKEN`

---

## 1. Vehicle Data & Live Status

| Endpoint | Method | Description | Key Query Parameters |
| :--- | :--- | :--- | :--- |
| `/vehicles` | `GET` | Get all vehicles on account | `only_active=true` |
| `/{vin}/state` | `GET` | Full vehicle state (charge, climate, drive, config) | `use_cache=false` |
| `/{vin}/status` | `GET` | Quick status string (`asleep`, `online`, `waiting_for_sleep`) | - |
| `/{vin}/battery` | `GET` | Battery charge state, range, limit | - |
| `/{vin}/location` | `GET` | GPS coordinates, street address, saved location name | - |
| `/{vin}/map` | `GET` | Static map image of vehicle location | `zoom=15`, `size=600x400` |
| `/{vin}/tire_pressure` | `GET` | 4-wheel TPMS readings in Bar | - |
| `/{vin}/weather` | `GET` | Ambient weather around vehicle | - |
| `/{vin}/consumption` | `GET` | Energy consumption since last charge | - |
| `/{vin}/firmware_alerts` | `GET` | Active firmware alerts / warning codes | - |
| `/{vin}/license_plate` | `GET` | Get vehicle license plate | - |
| `/{vin}/license_plate` | `POST`| Set vehicle license plate | `plate=STRING` |

---

## 2. Historical & Fleet Analytics

| Endpoint | Method | Description | Key Query Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/drives` | `GET` | Historical driving sessions | `from`, `to`, `limit=50` |
| `/{vin}/driving_path` | `GET` | GPS breadcrumb path for a given drive | `from`, `to` |
| `/{vin}/drives/tag` | `POST`| Tag drives (e.g., Business, Personal) | `tag=Business`, `drive_ids=[...]` |
| `/{vin}/charges` | `GET` | Historical charging sessions | `from`, `to`, `limit=50` |
| `/{vin}/charges/{id}/cost`| `POST`| Set electricity cost for charge session | `cost=12.50`, `currency=JPY` |
| `/charging_invoices` | `GET` | Invoices for all charging sessions | `from`, `to` |
| `/{vin}/idles` | `GET` | Vehicle idle / phantom drain sessions | `from`, `to`, `limit=50` |
| `/{vin}/last_idle` | `GET` | Data from when vehicle last stopped driving/charging | - |
| `/battery_health` | `GET` | Battery capacity, degradation % across fleet | - |
| `/{vin}/battery_health` | `GET` | Historical battery degradation measurements | - |
| `/{vin}/historical_states`| `GET` | Raw state snapshots during timeframe | `from`, `to` |

---

## 3. Vehicle Control Commands

All vehicle command endpoints are `POST` requests and support:
- `wait_for_completion=true|false`
- `retry_duration=SECONDS`

### 3.1 Door & Body Mechanisms
| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/wake` | `POST` | Wake vehicle from sleep mode | - |
| `/{vin}/command/lock` | `POST` | Lock vehicle doors | - |
| `/{vin}/command/unlock` | `POST` | Unlock vehicle doors *(Safety Guardrail)* | - |
| `/{vin}/command/front_trunk` | `POST` | Pop open front trunk (Frunk) *(Guardrail)* | - |
| `/{vin}/command/rear_trunk` | `POST` | Open or close powered rear trunk *(Guardrail)* | - |
| `/{vin}/command/open_tonneau` | `POST` | Open Cybertruck tonneau cover | - |
| `/{vin}/command/close_tonneau`| `POST` | Close Cybertruck tonneau cover | - |
| `/{vin}/command/vent_windows` | `POST` | Vent all 4 windows slightly | - |
| `/{vin}/command/close_windows`| `POST` | Fully roll up all windows | - |
| `/{vin}/command/vent_sunroof` | `POST` | Vent sunroof (legacy Model S) | - |
| `/{vin}/command/close_sunroof`| `POST` | Close sunroof (legacy Model S) | - |
| `/{vin}/command/flash_lights` | `POST` | Flash exterior headlights | - |
| `/{vin}/command/honk` | `POST` | Honk horn | - |
| `/{vin}/command/boombox` | `POST` | Play external sound/honk via Boombox | `sound=0..N` |
| `/{vin}/command/trigger_homelink`| `POST`| Trigger programmed HomeLink garage door | `lat`, `lon` |

### 3.2 Climate & Cabin Comfort
| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/command/start_climate` | `POST` | Turn on HVAC & precondition battery | - |
| `/{vin}/command/stop_climate` | `POST` | Turn off HVAC | - |
| `/{vin}/command/set_temperature` | `POST` | Set driver/passenger temperature | `temperature=22.0` |
| `/{vin}/command/set_seat_heating`| `POST` | Set seat heater level | `seat=0..5`, `level=0..3` (0: driver, 1: passenger, 2: RL, 4: RC, 5: RR) |
| `/{vin}/command/set_seat_cooling`| `POST` | Set seat ventilation level | `seat=0..1`, `level=0..3` |
| `/{vin}/command/start_defrost` | `POST` | Max windshield defrost mode | - |
| `/{vin}/command/stop_defrost` | `POST` | Turn off max defrost | - |
| `/{vin}/command/start_steering_wheel_heater` | `POST` | Turn on steering wheel heater | - |
| `/{vin}/command/stop_steering_wheel_heater` | `POST` | Turn off steering wheel heater | - |
| `/{vin}/command/set_cabin_overheat_protection` | `POST` | Cabin overheat protection mode | `mode=Off\|NoFan\|On` |
| `/{vin}/command/set_cabin_overheat_protection_temp`| `POST`| COP threshold temperature | `temperature=30\|35\|40` |
| `/{vin}/command/set_bio_defense_mode` | `POST` | Toggle Bioweapon Defense mode | `on=true\|false` |
| `/{vin}/command/set_climate_keeper_mode` | `POST` | Keep Climate, Dog, or Camp mode | `mode=0 (off), 1 (on), 2 (dog), 3 (camp)` |

### 3.3 Charging Controls
| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/command/start_charging` | `POST` | Resume charging | - |
| `/{vin}/command/stop_charging` | `POST` | Stop active charging | - |
| `/{vin}/command/set_charge_limit` | `POST` | Set battery charge target percentage | `limit=50..100` |
| `/{vin}/command/set_charging_amps` | `POST` | Set charging current in Amperes | `amps=5..48` |
| `/{vin}/command/open_charge_port` | `POST` | Open or unlock charge port | - |
| `/{vin}/command/close_charge_port`| `POST` | Close motorized charge port | - |
| `/{vin}/command/set_scheduled_charging` | `POST` | Configure scheduled charge start time | `enable=true`, `time=MINUTES_PAST_MIDNIGHT` |
| `/{vin}/command/set_scheduled_departure`| `POST` | Configure departure preconditioning | `enable=true`, `departure_time=...` |

### 3.4 Navigation & In-Car Routing
| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/command/share` | `POST` | Send destination address, Lat/Lng coordinates, or video URL | `value=35.1558,137.0401`, `locale=ja-JP` |

### 3.5 Security, Drivers & Speed Control
| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/command/enable_sentry` | `POST` | Activate Sentry Mode | - |
| `/{vin}/command/disable_sentry`| `POST` | Deactivate Sentry Mode | - |
| `/{vin}/command/enable_valet_mode` | `POST` | Enable Valet Mode | `pin=1234` |
| `/{vin}/command/disable_valet_mode`| `POST` | Disable Valet Mode | `pin=1234` |
| `/{vin}/command/enable_keyless_driving` | `POST` | Allow 2-minute keyless drive start | - |
| `/{vin}/command/set_speed_limit` | `POST` | Set speed limit in MPH | `limit_mph=75` |
| `/{vin}/command/enable_speed_limit` | `POST` | Turn on speed limiter | `pin=1234` |
| `/{vin}/command/disable_speed_limit`| `POST` | Turn off speed limiter | `pin=1234` |
| `/{vin}/command/schedule_software_update` | `POST` | Schedule pending OTA update | `offset_sec=0` |
| `/{vin}/command/cancel_software_update` | `POST` | Cancel scheduled OTA update | - |

---

## 4. Telemetry Configuration

| Endpoint | Method | Description | Parameters |
| :--- | :--- | :--- | :--- |
| `/{vin}/telemetry` | `GET` | Get current vehicle telemetry config | - |
| `/{vin}/telemetry` | `POST` | Update telemetry endpoints & interval | Body JSON config |
| `/{vin}/telemetry` | `DELETE`| Remove telemetry config | - |
