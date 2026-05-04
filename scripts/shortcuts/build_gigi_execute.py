#!/usr/bin/env python3
"""Build the hidden executor Shortcut for GIGI markers.

`GIGI Execute` accepts the marker provided by the app (`Shortcut Input`) and runs
only native/privileged branches. It contains no Dictate Text, no Begin Session,
and no Orchestrator action: GIGI has already captured and routed the command.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable

from shortcuts import FMT_SHORTCUT, FMT_TOML
from shortcuts import actions as a
from shortcuts.actions import conditions

from build_talk_to_gigi import (
    CATALOG,
    DynamicSetBrightnessAction,
    DynamicSetVolumeAction,
    DynamicURLAction,
    GetItemFromListAction,
    PauseMusicAction,
    PlayMusicAction,
    ReplaceTextAction,
    SaveToCameraRollAction,
    ShortcutBuilder,
    SkipBackAction,
    SkipForwardAction,
    TakeScreenshotAction,
    sha256,
    write_catalog_json,
    write_catalog_markdown,
)

SHORTCUT_NAME = "GIGI-Execute"
DEFAULT_OUT = Path("artifacts/shortcuts/GIGI-Execute.shortcut")
DEFAULT_TOML_OUT = Path("artifacts/shortcuts/GIGI-Execute.toml")
DEFAULT_CATALOG_OUT = Path("artifacts/shortcuts/catalog.json")
DEFAULT_DOC_OUT = Path("artifacts/shortcuts/catalog.md")


def build():
    b = ShortcutBuilder(name=SHORTCUT_NAME)

    b.get("Shortcut Input")
    b.set_var("GIGI_Result")
    b.text("")
    b.set_var("GIGI_Session")
    b.text("no")
    b.set_var("Spoken")
    b.text("no")
    b.set_var("Needs_Confirm")

    fixed = {
        "torch_on": (a.device.SetTorchAction, {"mode": "On"}),
        "torch_off": (a.device.SetTorchAction, {"mode": "Off"}),
        "wifi_on": (a.device.SetWiFiAction, {"on": "true"}),
        "wifi_off": (a.device.SetWiFiAction, {"on": "false"}),
        "bluetooth_on": (a.device.SetBluetoothAction, {"on": "true"}),
        "bluetooth_off": (a.device.SetBluetoothAction, {"on": "false"}),
        "airplane_on": (a.device.SetAirplaneModeAction, {"on": "true"}),
        "airplane_off": (a.device.SetAirplaneModeAction, {"on": "false"}),
        "dnd_on": (a.device.SetDoNotDisturbAction, {"enabled": "true"}),
        "dnd_off": (a.device.SetDoNotDisturbAction, {"enabled": "false"}),
        "lpm_on": (a.device.SetLowPowerModeAction, {"on": "true"}),
        "lpm_off": (a.device.SetLowPowerModeAction, {"on": "false"}),
        "music_play": (PlayMusicAction, {}),
        "music_pause": (PauseMusicAction, {}),
        "music_next": (SkipForwardAction, {}),
        "music_prev": (SkipBackAction, {}),
    }
    by_id = {entry.command_id: entry for entry in CATALOG}
    for command_id, (action_cls, kwargs) in fixed.items():
        b.branch_fixed(by_id[command_id], action_cls, **kwargs)

    def unsupported_silent_body() -> None:
        b.text("Silent mode is not available from Shortcuts on this iPhone/iOS version.")
        b.add(a.out.SpeakTextAction, language="English (United States)")
        b.mark_spoken()

    b.if_prefix("silent_on", "SYS:silent:on", unsupported_silent_body)
    b.if_prefix("silent_off", "SYS:silent:off", unsupported_silent_body)

    def screenshot_body() -> None:
        b.add(TakeScreenshotAction)
        b.add(SaveToCameraRollAction)
        b.mark_native_done()

    b.if_prefix("screenshot", "SYS:screenshot:", screenshot_body)

    def volume_body() -> None:
        b.extract_payload("SYS:volume:", "GIGI_Payload")
        b.get("GIGI_Payload")
        b.add(DynamicSetVolumeAction, level="{{GIGI_Payload}}")
        b.mark_native_done()

    b.if_prefix("volume", "SYS:volume:", volume_body)

    def brightness_body() -> None:
        b.extract_payload("SYS:brightness:", "GIGI_Payload")
        b.get("GIGI_Payload")
        b.add(DynamicSetBrightnessAction, level="{{GIGI_Payload}}")
        b.mark_native_done()

    b.if_prefix("brightness", "SYS:brightness:", brightness_body)

    def battery_body() -> None:
        b.add(a.device.GetBatteryLevelAction)
        b.set_var("Battery_Level")
        b.text("Battery is {{Battery_Level}} percent.")
        b.add(a.out.SpeakTextAction, language="English (United States)")
        b.mark_spoken()

    b.if_prefix("battery", "SYS:battery:", battery_body)

    def call_body() -> None:
        b.extract_payload("CALL:", "Call_Target")
        b.add(DynamicURLAction, url="tel:{{Call_Target}}")
        b.add(a.web.OpenURLAction)
        b.mark_native_done()

    b.if_prefix("call", "CALL:", call_body)

    def sms_body() -> None:
        b.extract_payload("SMS:", "SMS_Payload")
        b.get("SMS_Payload")
        b.add(a.text.SplitTextAction, separator_type="Custom", custom_separator="|")
        b.set_var("SMS_Parts")
        b.get("SMS_Parts")
        b.add(GetItemFromListAction, item_specifier="First Item")
        b.set_var("Message_Recipient")
        b.get("SMS_Parts")
        b.add(GetItemFromListAction, item_specifier="Last Item")
        b.set_var("Message_Body")
        b.add(a.messages.SendMessageAction, recepients="{{Message_Recipient}}", text="{{Message_Body}}")
        b.mark_native_done()

    b.if_prefix("sms", "SMS:", sms_body)

    def open_body() -> None:
        b.extract_payload("OPEN:", "Open_URL")
        b.add(DynamicURLAction, url="{{Open_URL}}")
        b.add(a.web.OpenURLAction)
        b.mark_native_done()

    b.if_prefix("open", "OPEN:", open_body)

    def search_url_body(command_id: str, prefix: str, url_template: str) -> None:
        def body() -> None:
            b.extract_payload(prefix, "Search_Query")
            b.get("Search_Query")
            b.add(a.web.URLEncodeAction, mode="Encode")
            b.set_var("Encoded_Query")
            b.add(DynamicURLAction, url=url_template)
            b.add(a.web.OpenURLAction)
            b.mark_native_done()

        b.if_prefix(command_id, prefix, body)

    search_url_body("spotify", "SYS:spotify:", "spotify:search:{{Encoded_Query}}")
    search_url_body("youtube", "SYS:youtube:", "youtube://www.youtube.com/results?search_query={{Encoded_Query}}")
    search_url_body("amazon", "SYS:amazon:", "https://www.amazon.com/s?k={{Encoded_Query}}")
    search_url_body("maps", "SYS:maps:", "maps://?q={{Encoded_Query}}")
    search_url_body("instagram", "SYS:instagram:", "instagram://user?username={{Encoded_Query}}")

    for command_id, prefix in (("speak", "SPEAK:"), ("error", "ERROR:")):
        def body(prefix=prefix) -> None:
            b.extract_payload(prefix, "Speech_Text")
            b.get("Speech_Text")
            b.add(a.out.SpeakTextAction, language="English (United States)")
            b.mark_spoken()

        b.if_prefix(command_id, prefix, body)

    b.if_prefix("stop", "STOP:", lambda: b.add(a.out.ExitAction))

    def app_handled_body() -> None:
        b.text("Handled in GIGI. Return to the app if you need the result.")
        b.add(a.out.SpeakTextAction, language="English (United States)")
        b.mark_spoken()

    # These markers are handled directly inside the GIGI app. Do not embed
    # GIGI AppIntents in this Shortcut: imported .shortcut files can show them
    # as Unknown Action on-device, creating broken blocks in Shortcuts.
    for command_id in ("alarm", "timer", "reminder", "weather", "location", "event"):
        entry = by_id[command_id]
        b.if_prefix(command_id, entry.marker.split("<", 1)[0], app_handled_body)

    gid = "gigi_default_speak"
    b.get("Spoken")
    b.add(conditions.IfAction, condition="Equals", compare_with="no", group_id=gid)
    b.get("GIGI_Result")
    b.add(a.out.SpeakTextAction, language="English (United States)")
    b.add(conditions.EndIfAction, group_id=gid)

    return b.shortcut


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the GIGI Execute marker executor Shortcut")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=".shortcut output path")
    parser.add_argument("--toml", type=Path, default=DEFAULT_TOML_OUT, help="debug TOML output path")
    parser.add_argument("--catalog-json", type=Path, default=DEFAULT_CATALOG_OUT, help="catalog JSON output path")
    parser.add_argument("--catalog-md", type=Path, default=DEFAULT_DOC_OUT, help="catalog Markdown output path")
    parser.add_argument("--no-toml", action="store_true", help="skip debug TOML output")
    parser.add_argument("--no-catalog", action="store_true", help="skip catalog JSON/Markdown outputs")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    shortcut = build()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("wb") as handle:
        shortcut.dump(handle, file_format=FMT_SHORTCUT)

    if not args.no_toml:
        args.toml.parent.mkdir(parents=True, exist_ok=True)
        with args.toml.open("wb") as handle:
            shortcut.dump(handle, file_format=FMT_TOML)

    if not args.no_catalog:
        write_catalog_json(args.catalog_json)
        write_catalog_markdown(args.catalog_md)

    print(f"Wrote {args.out}")
    print(f"Actions: {len(shortcut.actions)}")
    print(f"SHA256: {sha256(args.out)}")
    if not args.no_catalog:
        implemented = sum(1 for entry in CATALOG if entry.status.startswith("implemented"))
        dynamic = sum(1 for entry in CATALOG if entry.status == "generated-dynamic")
        appintent = sum(1 for entry in CATALOG if entry.status == "implemented-appintent")
        print(f"Catalog: {len(CATALOG)} entries ({implemented} implemented, {dynamic} dynamic, {appintent} appintent)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
