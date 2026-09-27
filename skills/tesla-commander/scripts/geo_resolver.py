import os
import re
import json
import urllib.request
import urllib.parse
import urllib.error
from typing import Optional, Dict, Any, Tuple

from env_loader import load_env_var

class GeoResolver:
    """
    Dual-engine Geographic Resolver:
    1. Vertex AI (gemini-3.8-flash) via VERTEX_API_KEY with context-aware relative search.
    2. Fallback to OpenStreetMap Nominatim when Vertex AI key is missing or encounters errors.
    """

    def __init__(self, vertex_key: Optional[str] = None):
        if vertex_key is not None:
            self.vertex_key = vertex_key
        else:
            self.vertex_key = load_env_var("VERTEX_API_KEY")

    def resolve(
        self,
        query: str,
        current_loc: Optional[Tuple[float, float]] = None,
        loc_desc: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Resolve natural language query to {name, address, lat, lng, engine, raw}.
        """
        query = query.strip()

        # Check if query is already exact coordinates: "35.1234, 137.5678"
        coord_match = re.match(r"^[-+]?([1-8]?\d(\.\d+)?|90(\.0+)?),\s*[-+]?(180(\.0+)?|((1[0-7]\d)|([1-9]?\d))(\.\d+)?)$", query)
        if coord_match:
            parts = [float(x.strip()) for x in query.split(",")]
            return {
                "name": f"Coordinates ({parts[0]}, {parts[1]})",
                "address": query,
                "lat": parts[0],
                "lng": parts[1],
                "engine": "direct_coordinates"
            }

        fallback_reason = "No VERTEX_API_KEY configured"
        # Try Vertex AI first if key exists
        if self.vertex_key:
            try:
                res = self._resolve_via_vertex(query, current_loc, loc_desc)
                if res and "lat" in res and "lng" in res:
                    res["engine"] = "vertex_ai_gemini_3_8_flash"
                    res["is_fallback"] = False
                    return res
            except Exception as e:
                fallback_reason = f"Vertex AI failed: {str(e)}"
                print(f"[Warning] Vertex AI resolution failed ({str(e)}), falling back to OpenStreetMap...")

        # Fallback to OpenStreetMap Nominatim
        res = self._resolve_via_osm(query, current_loc)
        res["is_fallback"] = True
        res["fallback_reason"] = fallback_reason
        return res

    def _resolve_via_vertex(
        self,
        query: str,
        current_loc: Optional[Tuple[float, float]] = None,
        loc_desc: Optional[str] = None
    ) -> Dict[str, Any]:
        """Call Vertex AI gemini-3.8-flash for structured geocoding."""
        url = "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash:generateContent"
        headers = {
            "x-goog-api-key": self.vertex_key,
            "Content-Type": "application/json"
        }

        context = ""
        if current_loc:
            context = f"The vehicle is currently located at latitude {current_loc[0]}, longitude {current_loc[1]}"
            if loc_desc:
                context += f" ({loc_desc})"
            context += ". Take this into account if the query is relative (e.g. 'nearest', 'nearby', '附近的', '离我最近的')."

        prompt = (
            f"The user wants to navigate their car in Japan to: \"{query}\".\n"
            f"{context}\n"
            "Task: Identify the exact destination intended by the user. "
            "Output the official Japanese name (name), the complete and precise Japanese street address (address), "
            "and the exact physical GPS latitude and longitude (lat, lng).\n"
            "Respond strictly in JSON format with schema:\n"
            "{\"name\": string, \"address\": string, \"lat\": number, \"lng\": number}\n"
            "Output ONLY the raw JSON object, no Markdown markdown block formatting."
        )

        body = {
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": prompt}]
                }
            ],
            "generationConfig": {
                "responseMimeType": "application/json",
                "thinkingConfig": {"thinkingBudget": 0}
            }
        }

        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST"
        )

        with urllib.request.urlopen(req, timeout=35) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if not candidates:
                raise RuntimeError("Empty response from Vertex AI")
            part_text = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
            parsed = json.loads(part_text)
            return {
                "name": parsed.get("name", query),
                "address": parsed.get("address", ""),
                "lat": float(parsed["lat"]),
                "lng": float(parsed["lng"])
            }

    def _resolve_via_osm(self, query: str, current_loc: Optional[Tuple[float, float]] = None) -> Dict[str, Any]:
        """Query OpenStreetMap Nominatim as open-source fallback."""
        # Clean common Chinese/Japanese relative search prefixes
        cleaned = re.sub(r"^(离我最近的|最近的|附近的|找一下|帮我找|去|到|近くの|最寄りの)\s*", "", query)
        cleaned = re.sub(r"\s*(离我最近|最近|附近)$", "", cleaned).strip()
        search_query = cleaned if cleaned else query

        base_url = "https://nominatim.openstreetmap.org/search"
        params = {
            "q": search_query,
            "format": "json",
            "countrycodes": "jp",
            "limit": 1,
            "addressdetails": 1
        }
        if current_loc:
            # Add small viewbox around current location (+/- 0.2 deg ~ 20km)
            lat, lng = current_loc
            params["viewbox"] = f"{lng-0.2},{lat+0.2},{lng+0.2},{lat-0.2}"
            params["bounded"] = 0

        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        headers = {
            "User-Agent": "TeslaCommander/1.0 (Tesla in Japan Navigation Resolver)"
        }

        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            results = json.loads(resp.read().decode("utf-8"))
            if not results:
                raise ValueError(f"OpenStreetMap could not find any location matching: '{search_query}'")
            item = results[0]
            return {
                "name": item.get("name") or search_query,
                "address": item.get("display_name", ""),
                "lat": float(item["lat"]),
                "lng": float(item["lon"]),
                "engine": "openstreetmap_nominatim"
            }
