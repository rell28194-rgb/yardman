#!/usr/bin/env python3
"""Extract exact stock wheel/tire targets from recovered CarX configuration JSON.

Inputs are AssetStudio-style JSON wrappers whose m_Script field contains CarX
XML dictionaries. Output is provenance metadata only; no private source media is
copied into the repository.
"""
from __future__ import annotations

import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

FILES = {
    "cars": "PlayerCars.json",
    "caps": "WheelCapDictionaryXML.json",
    "tires": "WheelTires.json",
}


def load_xml(path: Path) -> ET.Element:
    data = json.loads(path.read_text(encoding="utf-8"))
    text = data.get("m_Script")
    if not isinstance(text, str) or not text.strip():
        raise ValueError(f"{path} has no XML m_Script")
    return ET.fromstring(text)


def rows(root: ET.Element, tag: str) -> list[dict[str, str]]:
    return [dict(element.attrib) for element in root.iter() if element.tag == tag]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("configuration_dir", type=Path)
    parser.add_argument(
        "--prefab",
        action="append",
        default=[],
        help="Exact PlayerCar prefab to include; repeatable. Default: all.",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    roots = {key: load_xml(args.configuration_dir / filename) for key, filename in FILES.items()}
    cars = rows(roots["cars"], "PlayerCar")
    caps = {row.get("id", ""): row for row in rows(roots["caps"], "WheelCapMeta")}
    tires = {row.get("id", ""): row for row in rows(roots["tires"], "WheelTireMeta")}
    wanted = set(args.prefab)
    vehicles: list[dict[str, Any]] = []

    for car in cars:
        prefab = car.get("prefab", "")
        if wanted and prefab not in wanted:
            continue
        cap = caps.get(car.get("dWheelCapId", ""))
        tire = tires.get(car.get("dWheelTireId", ""))
        vehicles.append(
            {
                "car_id": int(car["id"]) if car.get("id", "").isdigit() else car.get("id"),
                "name": car.get("name", ""),
                "prefab": prefab,
                "identifier": car.get("identifier", ""),
                "stock_wheel_cap_id": car.get("dWheelCapId", ""),
                "stock_wheel_cap_prefab": cap.get("prefab", "") if cap else "",
                "stock_wheel_cap_name": cap.get("name", "") if cap else "",
                "stock_wheel_id": cap.get("wheelId", "") if cap else "",
                "stock_tire_id": car.get("dWheelTireId", ""),
                "stock_tire_left_prefab": tire.get("prefabLeft", "") if tire else "",
                "stock_tire_right_prefab": tire.get("prefabRight", "") if tire else "",
                "stock_tire_wheel_id": tire.get("wheelId", "") if tire else "",
                "complete": bool(
                    cap
                    and tire
                    and cap.get("prefab")
                    and tire.get("prefabLeft")
                    and tire.get("prefabRight")
                ),
            }
        )

    missing = sorted(wanted - {vehicle["prefab"] for vehicle in vehicles}) if wanted else []
    report: dict[str, Any] = {
        "format_version": 1,
        "tool": "yardman_carx_stock_fitment_extract",
        "configuration_files": FILES,
        "requested_prefabs": sorted(wanted),
        "missing_prefabs": missing,
        "vehicles": vehicles,
        "pass": not missing and all(vehicle["complete"] for vehicle in vehicles),
    }
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
