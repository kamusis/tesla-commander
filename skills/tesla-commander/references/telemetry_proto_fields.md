# Tesla Fleet Telemetry Field Reference

WebSocket Stream URL: `wss://streaming.tessie.com/{vin}?access_token={token}`

Fleet Telemetry emits events in real-time JSON format. Messages fall into 4 major event types:
1. `data`: High-frequency metric key-value updates.
2. `alerts`: Active or cleared vehicle firmware alarms.
3. `connectivity`: Vehicle network connection state (`CONNECTED` / `DISCONNECTED`).
4. `errors`: Protobuf decoding or schema incompatibility notices.

---

## 1. High-Frequency Metric Keys (`data`)

### Battery & Power (Electrical)
| Key | Type | Description |
| :--- | :--- | :--- |
| `Soc` | `doubleValue` | High-precision State of Charge percentage (e.g., `66.128`) |
| `EnergyRemaining` | `doubleValue` | Usable energy remaining in high-voltage pack (kWh) |
| `IdealBatteryRange` | `doubleValue` | Ideal vehicle range calculation (miles/km) |
| `RatedRange` | `doubleValue` | EPA/WLTP rated range (miles/km) |
| `EstBatteryRange` | `doubleValue` | Dynamic projected range based on recent consumption |
| `PackVoltage` | `doubleValue` | Total high-voltage pack voltage (Volts, e.g. `380.5`) |
| `PackCurrent` | `doubleValue` | High-voltage pack current (Amperes; negative = charging, positive = discharge) |
| `ModuleTempMin` | `doubleValue` | Lowest battery module temperature (°C) |
| `ModuleTempMax` | `doubleValue` | Highest battery module temperature (°C) |
| `LifetimeEnergyUsed` | `doubleValue` | Cumulative lifetime kilowatt-hours consumed |
| `LifetimeEnergyGainedRegen`| `doubleValue` | Cumulative lifetime kWh recovered from regenerative braking |

### Charging (AC & DC Supercharging)
| Key | Type | Description |
| :--- | :--- | :--- |
| `ACChargingPower` | `doubleValue` | Instantaneous AC charging power in kW (e.g. `6.200`) |
| `ACChargingEnergyIn` | `doubleValue` | Total energy delivered during this AC charging session (kWh) |
| `ChargeAmps` | `doubleValue` | Current drawn from charger (Amperes, e.g. `31.0`) |
| `ChargeVoltage` | `doubleValue` | Supply voltage from charging equipment (Volts) |
| `TimeToFullCharge` | `doubleValue` | Estimated time remaining to reach charge limit (Hours, e.g. `3.86`) |
| `FastChargerPresent` | `stringValue` | Whether connected to Supercharger/DC fast charger (`true`/`false`) |

### Dynamics, Speed & Location
| Key | Type | Description |
| :--- | :--- | :--- |
| `Location` | `locationValue` | Real-time GPS coordinate: `{"latitude": 35.xxx, "longitude": 137.xxx}` |
| `GpsHeading` | `doubleValue` | GPS compass heading in degrees (`0.0` - `360.0`) |
| `Speed` | `doubleValue` | Current vehicle speed (mph or km/h) |
| `Gear` | `stringValue` | Current drive gear (`P`, `R`, `N`, `D`) |
| `Odometer` | `doubleValue` | Cumulative vehicle odometer reading |
| `PedalPosition` | `doubleValue` | Accelerator pedal depression percentage (`0.0` - `100.0`) |

### Climate, Body & TPMS
| Key | Type | Description |
| :--- | :--- | :--- |
| `InsideTemp` | `doubleValue` | Cabin temperature sensor reading (°C) |
| `OutsideTemp` | `doubleValue` | Ambient exterior temperature (°C) |
| `HvacPower` | `doubleValue` | Power consumed by heating/cooling compressor & fan (kW) |
| `TpmsPressureFl` | `doubleValue` | Front Left tire pressure (Bar or PSI) |
| `TpmsPressureFr` | `doubleValue` | Front Right tire pressure (Bar or PSI) |
| `TpmsPressureRl` | `doubleValue` | Rear Left tire pressure (Bar or PSI) |
| `TpmsPressureRr` | `doubleValue` | Rear Right tire pressure (Bar or PSI) |

---

## 2. Alerts Event Schema (`alerts`)

Emitted whenever vehicle safety systems, driver assistance, or hardware components raise or clear an alert code.

```json
{
  "alerts": [
    {
      "name": "VCFRONT_a361_washerFluidLowMomentary",
      "audiences": ["Customer", "Service"],
      "startedAt": "2026-09-27T02:21:41.545Z",
      "endedAt": "2026-09-27T02:21:49.543Z"
    }
  ],
  "createdAt": "2026-09-27T02:21:50.000Z",
  "vin": "LRWXXXXXXXXXXXXXX"
}
```

---

## 3. Connectivity Event Schema (`connectivity`)

Emitted when the car associates or drops its telemetry session with the telemetry gateway:

```json
{
  "vin": "LRWXXXXXXXXXXXXXX",
  "connectionId": "913a422e-7169-48fa-a4a4-2eab9f12ab34",
  "status": "CONNECTED",
  "createdAt": "2026-09-27T02:00:00.000Z"
}
```
