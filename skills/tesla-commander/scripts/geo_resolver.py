import os
import re
import json
import math
import urllib.request
import urllib.parse
import urllib.error
from typing import Optional, Dict, Any, Tuple, List

from env_loader import load_env_var

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculates the great-circle distance between two GPS coordinates in kilometers."""
    r = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2.0) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2.0) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return round(r * c, 1)

class GeoResolver:
    """
    Dual-engine Geographic Resolver:
    1. Vertex AI (gemini-3.8-flash) via VERTEX_API_KEY with context-aware relative search & multi-candidate ranking.
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
        Resolve natural language query to destination candidates with backward-compatible top-level keys.
        Returns: {name, address, lat, lng, engine, is_fallback, candidates: [...]}
        """
        query = query.strip()

        # Check if query is already exact coordinates: "35.1234, 137.5678"
        coord_match = re.match(r"^[-+]?([1-8]?\d(\.\d+)?|90(\.0+)?),\s*[-+]?(180(\.0+)?|((1[0-7]\d)|([1-9]?\d))(\.\d+)?)$", query)
        if coord_match:
            parts = [float(x.strip()) for x in query.split(",")]
            dist = haversine_km(current_loc[0], current_loc[1], parts[0], parts[1]) if current_loc else None
            cand = {
                "name": f"Coordinates ({parts[0]:.4f}, {parts[1]:.4f})",
                "address": query,
                "lat": parts[0],
                "lng": parts[1],
                "distance_km": dist,
                "engine": "direct_coordinates"
            }
            return {
                "name": cand["name"],
                "address": cand["address"],
                "lat": cand["lat"],
                "lng": cand["lng"],
                "distance_km": dist,
                "engine": "direct_coordinates",
                "is_fallback": False,
                "candidates": [cand]
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
        """Call Vertex AI gemini-3.8-flash for structured geocoding with multi-candidate support."""
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
            "Task: Identify matching destination(s) intended by the user. Provide up to 4 most relevant candidates.\n"
            "For each candidate, provide:\n"
            "- \"name\": official Japanese or common place/store name (e.g. \"スターバックス コーヒー 栄レイヤード久屋大通パーク店\")\n"
            "- \"address\": complete and precise Japanese street address\n"
            "- \"lat\": physical GPS latitude (number)\n"
            "- \"lng\": physical GPS longitude (number)\n"
            "Respond strictly in JSON format with schema:\n"
            "{\"candidates\": [{\"name\": string, \"address\": string, \"lat\": number, \"lng\": number}]}\n"
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
            candidates_raw = data.get("candidates", [])
            if not candidates_raw:
                raise RuntimeError("Empty response from Vertex AI")
            part_text = candidates_raw[0].get("content", {}).get("parts", [{}])[0].get("text", "")
            parsed = json.loads(part_text)

            cands_list = parsed.get("candidates", [])
            if not cands_list and "lat" in parsed and "lng" in parsed:
                cands_list = [parsed]

            formatted_cands = []
            for c in cands_list:
                lat = float(c["lat"])
                lng = float(c["lng"])
                dist = haversine_km(current_loc[0], current_loc[1], lat, lng) if current_loc else None
                formatted_cands.append({
                    "name": c.get("name", query),
                    "address": c.get("address", ""),
                    "lat": lat,
                    "lng": lng,
                    "distance_km": dist,
                    "engine": "vertex_ai_gemini_3_8_flash"
                })

            if not formatted_cands:
                raise RuntimeError("Vertex AI parsed 0 candidates")

            if current_loc:
                formatted_cands.sort(key=lambda x: x["distance_km"] if x["distance_km"] is not None else 999999)

            primary = formatted_cands[0]
            return {
                "name": primary["name"],
                "address": primary["address"],
                "lat": primary["lat"],
                "lng": primary["lng"],
                "distance_km": primary.get("distance_km"),
                "candidates": formatted_cands
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
            "limit": 4,
            "addressdetails": 1
        }
        if current_loc:
            lat, lng = current_loc
            params["viewbox"] = f"{lng-0.2},{lat+0.2},{lng+0.2},{lat-0.2}"
            params["bounded"] = 0

        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        headers = {
            "User-Agent": "TeslaCommander/2.0 (Tesla in Japan Navigation Resolver)"
        }

        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            results = json.loads(resp.read().decode("utf-8"))
            if not results:
                raise ValueError(f"OpenStreetMap could not find any location matching: '{search_query}'")

            formatted_cands = []
            for item in results:
                lat = float(item["lat"])
                lng = float(item["lon"])
                dist = haversine_km(current_loc[0], current_loc[1], lat, lng) if current_loc else None
                formatted_cands.append({
                    "name": item.get("name") or search_query,
                    "address": item.get("display_name", ""),
                    "lat": lat,
                    "lng": lng,
                    "distance_km": dist,
                    "engine": "openstreetmap_nominatim"
                })

            if current_loc:
                formatted_cands.sort(key=lambda x: x["distance_km"] if x["distance_km"] is not None else 999999)

            primary = formatted_cands[0]
            return {
                "name": primary["name"],
                "address": primary["address"],
                "lat": primary["lat"],
                "lng": primary["lng"],
                "distance_km": primary.get("distance_km"),
                "engine": "openstreetmap_nominatim",
                "candidates": formatted_cands
            }
