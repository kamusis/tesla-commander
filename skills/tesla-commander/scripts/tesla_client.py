import os
import re
import json
import urllib.request
import urllib.error
import urllib.parse
from typing import Optional, Dict, Any, List

from env_loader import load_env_var

class TessieClient:
    """Tessie REST API Client with automatic active vehicle resolution."""
    BASE_URL = "https://api.tessie.com"

    def __init__(self, token: Optional[str] = None):
        self.token = token or load_env_var("TESSIE_ACCESS_TOKEN")
        if not self.token:
            raise ValueError("TESSIE_ACCESS_TOKEN not found in environment, .env, or shell profiles")
        self._cached_vin: Optional[str] = None

    def _request(self, path: str, method: str = "GET", params: Optional[Dict[str, Any]] = None, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send HTTP request to Tessie API."""
        url = f"{self.BASE_URL}{path}"
        if params:
            encoded_params = {}
            for k, v in params.items():
                if v is True:
                    encoded_params[k] = "true"
                elif v is False:
                    encoded_params[k] = "false"
                elif v is not None:
                    encoded_params[k] = v
            query = urllib.parse.urlencode(encoded_params)
            url = f"{url}?{query}"

        data = json.dumps(body).encode("utf-8") if body else None
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "User-Agent": "TeslaCommander/1.0"
        }

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            try:
                err_json = json.loads(err_body)
                raise RuntimeError(f"Tessie API error {e.code}: {err_json.get('error', err_body)}")
            except json.JSONDecodeError:
                raise RuntimeError(f"Tessie API error {e.code}: {err_body}")
        except Exception as e:
            raise RuntimeError(f"Network error communicating with Tessie: {str(e)}")

    def get_vehicles(self) -> List[Dict[str, Any]]:
        """List all vehicles associated with the account."""
        resp = self._request("/vehicles")
        return resp.get("results", [])

    def _format_vehicles_table(self, vehicles: List[Dict[str, Any]]) -> str:
        """Format vehicle list into a clear terminal summary table."""
        headers = ["#", "Vehicle Name", "Model", "Color", "VIN", "Active"]
        rows = []
        for i, v in enumerate(vehicles, 1):
            ls = v.get("last_state", {})
            name = ls.get("display_name") or ls.get("vehicle_state", {}).get("vehicle_name") or "Unnamed"
            cfg = ls.get("vehicle_config", {})
            model = cfg.get("model") or cfg.get("car_type") or "Tesla"
            color = cfg.get("exterior_color") or "Unknown"
            vin = v.get("vin", "Unknown")
            active = "Yes" if v.get("is_active") else "No"
            rows.append([str(i), name, model, color, vin, active])

        col_widths = [len(h) for h in headers]
        for row in rows:
            for idx, val in enumerate(row):
                col_widths[idx] = max(col_widths[idx], len(str(val)))

        header_line = " | ".join(h.ljust(col_widths[idx]) for idx, h in enumerate(headers))
        sep_line = "-+-".join("-" * col_widths[idx] for idx in range(len(headers)))
        body_lines = [" | ".join(str(val).ljust(col_widths[idx]) for idx, val in enumerate(row)) for row in rows]
        return "\n".join([header_line, sep_line] + body_lines)

    def resolve_vin(self, target: Optional[str] = None) -> str:
        """
        Resolve target to a valid VIN.
        Priority:
        1. Explicit target passed via --vin / function argument.
        2. MY_TESLA_VIN environment variable (avoids extra API network call).
        3. Query Tessie API for active vehicle:
           - If 1 active vehicle: auto-select.
           - If >1 active vehicles: output vehicle details table and prompt user to specify.
        """
        # 1. Explicit target passed
        if target:
            if len(target) == 17 and target.isalnum():
                return target
            vehicles = self.get_vehicles()
            target_lower = target.lower()
            for v in vehicles:
                name = (v.get("last_state", {}).get("display_name") or "").lower()
                vin = v.get("vin", "")
                if target_lower in name or target_lower in vin.lower():
                    return vin
            raise ValueError(f"No vehicle matched name/VIN: '{target}'")

        # 2. Check MY_TESLA_VIN environment variable
        my_vin = load_env_var("MY_TESLA_VIN")
        if my_vin and len(my_vin.strip()) == 17:
            return my_vin.strip()

        # 3. Use cached VIN if already resolved in this session
        if self._cached_vin:
            return self._cached_vin

        # 4. Fallback to API query
        vehicles = self.get_vehicles()
        if not vehicles:
            raise RuntimeError("No vehicles found in Tessie account.")

        active_vehicles = [v for v in vehicles if v.get("is_active")]

        if len(active_vehicles) == 1:
            self._cached_vin = active_vehicles[0].get("vin")
            return self._cached_vin
        elif len(active_vehicles) > 1:
            summary = self._format_vehicles_table(active_vehicles)
            raise RuntimeError(
                f"Multiple active vehicles found ({len(active_vehicles)}). "
                f"Please specify which vehicle to use via --vin or set MY_TESLA_VIN in your shell profile or .env:\n\n{summary}"
            )
        else:
            if len(vehicles) == 1:
                self._cached_vin = vehicles[0].get("vin")
                return self._cached_vin
            summary = self._format_vehicles_table(vehicles)
            raise RuntimeError(
                f"No active vehicles found among {len(vehicles)} vehicles. "
                f"Please specify which vehicle to use via --vin or set MY_TESLA_VIN in your shell profile or .env:\n\n{summary}"
            )

    def get_state(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Get latest complete state of the vehicle."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/state")

    def get_status(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Get quick status (asleep, online, etc.)."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/status")

    def get_location(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Get current GPS coordinates and street address."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/location")

    def get_battery(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Get detailed battery state."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/battery")

    def get_battery_health(self) -> List[Dict[str, Any]]:
        """Get battery health across all vehicles."""
        resp = self._request("/battery_health")
        return resp.get("results", [])

    def get_tire_pressure(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Get tire pressure in bar."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/tire_pressure")

    def wake(self, vin: Optional[str] = None) -> Dict[str, Any]:
        """Wake vehicle from sleep."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/wake", method="POST")

    def send_command(self, action: str, vin: Optional[str] = None, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send vehicle command (honk, flash_lights, lock, etc.)."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/command/{action}", method="POST", params=params)

    def set_climate(self, action: str, vin: Optional[str] = None, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Climate control actions."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/command/{action}", method="POST", params=params)

    def set_charging(self, action: str, vin: Optional[str] = None, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Charging control actions."""
        v = self.resolve_vin(vin)
        return self._request(f"/{v}/command/{action}", method="POST", params=params)

    def share_navigation(self, destination: str, vin: Optional[str] = None, locale: str = "ja-JP") -> Dict[str, Any]:
        """Send navigation address or coordinates to vehicle."""
        v = self.resolve_vin(vin)
        params = {
            "value": destination,
            "locale": locale,
            "wait_for_completion": True
        }
        return self._request(f"/{v}/command/share", method="POST", params=params)

    def get_drives(self, vin: Optional[str] = None, limit: int = 10) -> List[Dict[str, Any]]:
        """Get recent driving history."""
        v = self.resolve_vin(vin)
        resp = self._request(f"/{v}/drives", params={"limit": limit})
        return resp.get("results", [])

    def get_charges(self, vin: Optional[str] = None, limit: int = 10) -> List[Dict[str, Any]]:
        """Get recent charging sessions."""
        v = self.resolve_vin(vin)
        resp = self._request(f"/{v}/charges", params={"limit": limit})
        return resp.get("results", [])
