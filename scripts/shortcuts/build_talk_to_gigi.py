#!/usr/bin/env python3
"""Deterministically build the generated Talk to GIGI Shortcut.

The generator is the repo source of truth for the Shortcut execution shell.  It
intentionally keeps parsing/intelligence in the GIGI AppIntent layer:

    Begin GIGI session → dictate → Orchestrate with GIGI → execute marker →
    Confirm GIGI action

The Shortcut only branches on boundary markers returned by GIGI, for example
``SYS:torch:on``, ``CALL:+15551234567``, ``SMS:+15551234567|I'm late`` and
``OPEN:spotify://``.

Some Shortcuts actions are not modeled by shortcuts-py. Those commands are
still emitted by GIGI and the generated Shortcut routes them through
`GigiExecuteSystemCommandIntent`, rather than creating fake TODO branches.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

try:
    import shortcuts
    from shortcuts import FMT_SHORTCUT, FMT_TOML, Shortcut, actions as a
    from shortcuts.actions import actions_registry, conditions
    from shortcuts.actions.base import (
        BaseAction,
        BooleanField,
        ChoiceField,
        Field,
        FloatField,
        GroupIDField,
        IntegerField,
        VariablesField,
    )
except Exception as exc:  # pragma: no cover - exercised by CLI dependency check
    print(
        "Missing dependency: shortcuts-py is required to build Talk-to-GIGI.shortcut.\n"
        "Install in the repo/tooling environment, then rerun this script.\n"
        f"Original error: {exc}",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


BUNDLE_ID = "com.killsiri.GIGI"
BEGIN_SESSION_INTENT = "GigiBeginSessionIntent"
ORCHESTRATOR_INTENT = "GigiOrchestratorIntent"
CONFIRM_ACTION_INTENT = "GigiConfirmActionIntent"
EXECUTE_SYSTEM_COMMAND_INTENT = "GigiExecuteSystemCommandIntent"
SHORTCUT_NAME = "Talk to GIGI"
DEFAULT_OUT = Path("artifacts/shortcuts/Talk-to-GIGI.shortcut")
DEFAULT_TOML_OUT = Path("artifacts/shortcuts/Talk-to-GIGI.toml")
DEFAULT_CATALOG_OUT = Path("artifacts/shortcuts/catalog.json")
DEFAULT_DOC_OUT = Path("artifacts/shortcuts/catalog.md")

# Apple supports these conditions; shortcuts-py only exposes a smaller subset.
IF_CHOICES = ("Equals", "Contains", "Begins With", "Ends With", "Has Any Value")
conditions.IfAction.condition = ChoiceField("WFCondition", choices=IF_CHOICES)
conditions.IfAction.condition._attr = "condition"


class DictateTextAction(BaseAction):
    itype = "is.workflow.actions.dictatetext"
    keyword = "dictate_text"
    language = ChoiceField(
        "WFDictateTextLanguage",
        choices=("English (US)", "English (UK)", "Italian"),
        required=False,
        default="English (US)",
    )
    stop_listening = ChoiceField(
        "WFDictateTextStopListening",
        choices=("After Pause", "After Short Pause", "On Tap"),
        required=False,
        default="After Pause",
    )


class RunAppIntentAction(BaseAction):
    """Run App Intent.

    shortcuts-py does not ship this action yet; the raw fields are the stable
    parameters exported by the prototype Shortcut.
    """

    itype = "is.workflow.actions.runappintent"
    keyword = "run_app_intent"
    bundle_id = Field("AppIntentBundleIdentifier")
    intent_name = Field("AppIntentIdentifier")
    input_text = VariablesField("text", required=False)
    marker = VariablesField("marker", required=False)
    session_id = VariablesField("sessionID", required=False)
    result = VariablesField("result", required=False)
    outcome = VariablesField("outcome", required=False)


class TakeScreenshotAction(BaseAction):
    itype = "is.workflow.actions.takescreenshot"
    keyword = "take_screenshot"
    main_screen = BooleanField("WFTakeScreenshotMainScreenOnly", default=True, required=False)


class SaveToCameraRollAction(BaseAction):
    itype = "is.workflow.actions.savetocameraroll"
    keyword = "save_to_camera_roll"


class ReplaceTextAction(BaseAction):
    itype = "is.workflow.actions.text.replace"
    keyword = "replace_text"
    find = VariablesField("WFReplaceTextFind")
    replace = VariablesField("WFReplaceTextReplace")
    case_sensitive = BooleanField("WFReplaceTextCaseSensitive", default=True, required=False)
    regex = BooleanField("WFReplaceTextRegularExpression", default=False, required=False)


class GetItemFromListAction(BaseAction):
    itype = "is.workflow.actions.getitemfromlist"
    keyword = "get_item_from_list"
    item_specifier = ChoiceField(
        "WFItemSpecifier",
        choices=("First Item", "Last Item", "Item At Index"),
        default="Item At Index",
        required=False,
    )
    index = IntegerField("WFItemIndex", default=1, required=False)


class DynamicURLAction(BaseAction):
    """URL action whose URL can contain Shortcut variables.

    shortcuts-py's stock URLAction models the field as a static string; GIGI's
    generated branches need dynamic URLs such as `tel:{{Call_Target}}` and
    search deep links built from `{{Encoded_Query}}`.
    """

    itype = "is.workflow.actions.url"
    keyword = "url_dynamic"
    url = VariablesField("WFURLActionURL")


class SetSilentModeAction(BaseAction):
    itype = "is.workflow.actions.silentmode.set"
    keyword = "set_silent_mode"
    on = BooleanField("OnValue")


class PlayMusicAction(BaseAction):
    itype = "is.workflow.actions.playmusic"
    keyword = "play_music"


class PauseMusicAction(BaseAction):
    itype = "is.workflow.actions.pausemusic"
    keyword = "pause_music"


class SkipForwardAction(BaseAction):
    itype = "is.workflow.actions.skipforward"
    keyword = "skip_forward"


class SkipBackAction(BaseAction):
    itype = "is.workflow.actions.skipback"
    keyword = "skip_back"


class DynamicSetVolumeAction(BaseAction):
    """Set Volume with a dynamic marker payload.

    The stock shortcuts-py action uses FloatField, which cannot serialize a
    Shortcut variable.  Apple Shortcuts may still reject this typed field on
    import; README documents that limitation.
    """

    itype = "is.workflow.actions.setvolume"
    keyword = "set_volume_dynamic"
    level = VariablesField("WFVolume")


class DynamicSetBrightnessAction(BaseAction):
    """Set Brightness with a dynamic marker payload; see DynamicSetVolumeAction."""

    itype = "is.workflow.actions.setbrightness"
    keyword = "set_brightness_dynamic"
    level = VariablesField("WFBrightness")


CUSTOM_ACTIONS = (
    DictateTextAction,
    RunAppIntentAction,
    TakeScreenshotAction,
    SaveToCameraRollAction,
    ReplaceTextAction,
    GetItemFromListAction,
    DynamicURLAction,
    SetSilentModeAction,
    PlayMusicAction,
    PauseMusicAction,
    SkipForwardAction,
    SkipBackAction,
    DynamicSetVolumeAction,
    DynamicSetBrightnessAction,
)
for action_cls in CUSTOM_ACTIONS:
    if action_cls not in actions_registry.actions:
        actions_registry.register_action(action_cls)


@dataclass(frozen=True)
class CatalogEntry:
    command_id: str
    marker: str
    native_action: str
    status: str
    test_phrase: str
    notes: str = ""


CATALOG: tuple[CatalogEntry, ...] = (
    CatalogEntry("torch_on", "SYS:torch:on", "Set Flashlight On", "implemented", "turn on flashlight"),
    CatalogEntry("torch_off", "SYS:torch:off", "Set Flashlight Off", "implemented", "turn off flashlight"),
    CatalogEntry("volume", "SYS:volume:<0-100>", "Set Volume", "generated-dynamic", "set volume to 30", "Dynamic typed numeric Shortcut field; validate import on device."),
    CatalogEntry("brightness", "SYS:brightness:<0-100>", "Set Brightness", "generated-dynamic", "set brightness to 80", "Dynamic typed numeric Shortcut field; validate import on device."),
    CatalogEntry("wifi_on", "SYS:wifi:on", "Set Wi-Fi On", "implemented", "turn on wifi"),
    CatalogEntry("wifi_off", "SYS:wifi:off", "Set Wi-Fi Off", "implemented", "turn off wifi"),
    CatalogEntry("bluetooth_on", "SYS:bluetooth:on", "Set Bluetooth On", "implemented", "turn on bluetooth"),
    CatalogEntry("bluetooth_off", "SYS:bluetooth:off", "Set Bluetooth Off", "implemented", "turn off bluetooth"),
    CatalogEntry("airplane_on", "SYS:airplane:on", "Set Airplane Mode On", "implemented", "turn on airplane mode"),
    CatalogEntry("airplane_off", "SYS:airplane:off", "Set Airplane Mode Off", "implemented", "turn off airplane mode"),
    CatalogEntry("dnd_on", "SYS:dnd:on", "Set Focus / DND On", "implemented", "turn on do not disturb"),
    CatalogEntry("dnd_off", "SYS:dnd:off", "Set Focus / DND Off", "implemented", "turn off do not disturb"),
    CatalogEntry("silent_on", "SYS:silent:on", "Set Silent Mode On", "implemented-custom", "silent mode"),
    CatalogEntry("silent_off", "SYS:silent:off", "Set Silent Mode Off", "implemented-custom", "turn off silent mode"),
    CatalogEntry("lpm_on", "SYS:lpm:on", "Set Low Power Mode On", "implemented", "turn on low power mode"),
    CatalogEntry("lpm_off", "SYS:lpm:off", "Set Low Power Mode Off", "implemented", "turn off low power mode"),
    CatalogEntry("screenshot", "SYS:screenshot:", "Take Screenshot + Save", "implemented-custom", "take screenshot"),
    CatalogEntry("alarm", "SYS:alarm:<HH-MM>", "GIGI executor AppIntent notification alarm", "implemented-appintent", "set alarm at 7:30", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Create Alarm action mapping."),
    CatalogEntry("timer", "SYS:timer:<minutes>", "GIGI executor AppIntent notification timer", "implemented-appintent", "set timer for 10 minutes", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Start Timer action mapping."),
    CatalogEntry("reminder", "SYS:reminder:<body>", "GIGI executor AppIntent EventKit reminder", "implemented-appintent", "remind me to call Marco", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Add Reminder action mapping."),
    CatalogEntry("music_play", "SYS:music:play", "Play Music", "implemented-custom", "play music"),
    CatalogEntry("music_pause", "SYS:music:pause", "Pause Music", "implemented-custom", "pause music"),
    CatalogEntry("music_next", "SYS:music:next", "Skip Forward", "implemented-custom", "next track"),
    CatalogEntry("music_prev", "SYS:music:prev", "Skip Back", "implemented-custom", "previous track"),
    CatalogEntry("weather", "SYS:weather:", "GIGI executor AppIntent weather lookup", "implemented-appintent", "what's the weather", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Weather action mapping."),
    CatalogEntry("battery", "SYS:battery:", "Get Battery_Level + Speak", "implemented", "what's the battery"),
    CatalogEntry("location", "SYS:location:", "GIGI executor AppIntent current location", "implemented-appintent", "where am I", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Current Location action mapping."),
    CatalogEntry("event", "SYS:event:<payload>", "GIGI executor AppIntent EventKit event", "implemented-appintent", "create calendar event", "Generated Shortcut calls GigiExecuteSystemCommandIntent because shortcuts-py has no verified Calendar Event action mapping."),
    CatalogEntry("call", "CALL:<number>", "Open tel: URL", "implemented", "call Mom"),
    CatalogEntry("sms", "SMS:<number>|<body>", "Send Message", "implemented", "text Fede saying I'm late"),
    CatalogEntry("open", "OPEN:<url>", "Open URL", "implemented", "open Spotify"),
    CatalogEntry("spotify", "SYS:spotify:<query>", "Open Spotify search URL", "implemented", "play Queen on Spotify"),
    CatalogEntry("youtube", "SYS:youtube:<query>", "Open YouTube search URL", "implemented", "watch lofi on YouTube"),
    CatalogEntry("amazon", "SYS:amazon:<query>", "Open Amazon search URL", "implemented", "search shoes on Amazon"),
    CatalogEntry("maps", "SYS:maps:<query>", "Open Apple Maps search URL", "implemented", "navigate to Times Square"),
    CatalogEntry("instagram", "SYS:instagram:<query>", "Open Instagram URL", "implemented", "Instagram user Marco"),
    CatalogEntry("speak", "SPEAK:<text>", "Speak Text", "implemented", "tell me a joke"),
    CatalogEntry("stop", "STOP:", "Exit Shortcut", "implemented", "stop"),
    CatalogEntry("error", "ERROR:<text>", "Speak Text", "implemented", "unavailable command"),
)


class ShortcutBuilder:
    def __init__(self, name: str = SHORTCUT_NAME):
        self.shortcut = Shortcut(name=name)

    def add(self, action_cls: type[BaseAction], **data):
        action = action_cls(data=data)
        self.shortcut.actions.append(action)
        return action

    def get(self, name: str) -> None:
        self.add(a.variables.GetVariableAction, name=name)

    def set_var(self, name: str) -> None:
        self.add(a.variables.SetVariableAction, name=name)

    def text(self, text: str) -> None:
        self.add(a.text.TextAction, text=text)

    def mark_spoken(self) -> None:
        self.text("yes")
        self.set_var("Spoken")

    def mark_confirm_needed(self) -> None:
        self.text("yes")
        self.set_var("Needs_Confirm")

    def mark_native_done(self) -> None:
        self.mark_spoken()
        self.mark_confirm_needed()

    def extract_payload(self, prefix: str, variable_name: str) -> None:
        self.get("GIGI_Result")
        self.add(ReplaceTextAction, find=prefix, replace="", case_sensitive="true", regex="false")
        self.set_var(variable_name)

    def if_prefix(self, command_id: str, prefix: str, body: Callable[[], None]) -> None:
        gid = f"gigi_{command_id}"
        self.get("GIGI_Result")
        self.add(conditions.IfAction, condition="Begins With", compare_with=prefix, group_id=gid)
        body()
        self.add(conditions.EndIfAction, group_id=gid)

    def branch_fixed(self, entry: CatalogEntry, action_cls: type[BaseAction], **data) -> None:
        prefix = entry.marker.split("<", 1)[0] if "<" in entry.marker else entry.marker

        def body() -> None:
            self.add(action_cls, **data)
            self.mark_native_done()

        self.if_prefix(entry.command_id, prefix, body)


def build() -> Shortcut:
    b = ShortcutBuilder()

    b.add(
        RunAppIntentAction,
        bundle_id=BUNDLE_ID,
        intent_name=BEGIN_SESSION_INTENT,
    )
    b.set_var("GIGI_Session")

    b.text("no")
    b.set_var("Spoken")
    b.text("no")
    b.set_var("Needs_Confirm")

    repeat_id = "gigi_repeat"
    b.add(a.scripting.RepeatStartAction, count=50, group_id=repeat_id)

    b.add(DictateTextAction)
    b.set_var("Dictated")

    for stop_word in ("stop", "cancel"):
        gid = f"gigi_stop_word_{stop_word}"
        b.get("Dictated")
        b.add(conditions.IfAction, condition="Equals", compare_with=stop_word, group_id=gid)
        b.add(a.out.ExitAction)
        b.add(conditions.EndIfAction, group_id=gid)

    b.get("Dictated")
    b.add(
        RunAppIntentAction,
        bundle_id=BUNDLE_ID,
        intent_name=ORCHESTRATOR_INTENT,
        input_text="{{Dictated}}",
        session_id="{{GIGI_Session}}",
    )
    b.set_var("GIGI_Result")

    b.text("no")
    b.set_var("Spoken")
    b.text("no")
    b.set_var("Needs_Confirm")

    # Fixed SYS branches.
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
        "silent_on": (SetSilentModeAction, {"on": "true"}),
        "silent_off": (SetSilentModeAction, {"on": "false"}),
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

    # CALL:<number> via tel: URL. This is deterministic and avoids an unmapped
    # shortcuts-py Phone/Call action while still using iOS native call handling.
    def call_body() -> None:
        b.extract_payload("CALL:", "Call_Target")
        b.add(DynamicURLAction, url="tel:{{Call_Target}}")
        b.add(a.web.OpenURLAction)
        b.mark_native_done()

    b.if_prefix("call", "CALL:", call_body)

    # SMS:<number>|<body>
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

    # SPEAK:/ERROR: explicit speech result from orchestrator.
    for command_id, prefix in (("speak", "SPEAK:"), ("error", "ERROR:")):
        def body(prefix=prefix) -> None:
            b.extract_payload(prefix, "Speech_Text")
            b.get("Speech_Text")
            b.add(a.out.SpeakTextAction, language="English (United States)")
            b.mark_spoken()

        b.if_prefix(command_id, prefix, body)

    b.if_prefix("stop", "STOP:", lambda: b.add(a.out.ExitAction))

    # Commands whose native Shortcut actions are not reliably serializable by
    # shortcuts-py yet still remain in the generated Shortcut as explicit GIGI
    # executor AppIntent branches. This keeps the catalog full-scope without
    # hiding unfinished Shortcuts mappings behind fake TODO branches.
    def executor_body() -> None:
        b.add(
            RunAppIntentAction,
            bundle_id=BUNDLE_ID,
            intent_name=EXECUTE_SYSTEM_COMMAND_INTENT,
            marker="{{GIGI_Result}}",
            session_id="{{GIGI_Session}}",
        )
        b.set_var("GIGI_Execution_Result")
        b.get("GIGI_Execution_Result")
        b.add(a.out.SpeakTextAction, language="English (United States)")
        b.mark_spoken()

    for command_id in ("alarm", "timer", "reminder", "weather", "location", "event"):
        entry = by_id[command_id]
        b.if_prefix(command_id, entry.marker.split("<", 1)[0], executor_body)

    # Native actions are confirmed by GIGI after the Shortcut has executed them,
    # preserving the product model that GIGI is the conversational orchestrator
    # and Shortcuts is only the privileged execution arm.
    gid = "gigi_confirm_native_action"
    b.get("Needs_Confirm")
    b.add(conditions.IfAction, condition="Equals", compare_with="yes", group_id=gid)
    b.add(
        RunAppIntentAction,
        bundle_id=BUNDLE_ID,
        intent_name=CONFIRM_ACTION_INTENT,
        result="{{GIGI_Result}}",
        session_id="{{GIGI_Session}}",
    )
    b.set_var("GIGI_Confirmation")
    b.get("GIGI_Confirmation")
    b.add(a.out.SpeakTextAction, language="English (United States)")
    b.add(conditions.EndIfAction, group_id=gid)

    # Default Speak Text fallback when no native branch marked the command handled.
    gid = "gigi_default_speak"
    b.get("Spoken")
    b.add(conditions.IfAction, condition="Equals", compare_with="no", group_id=gid)
    b.get("GIGI_Result")
    b.add(a.out.SpeakTextAction, language="English (United States)")
    b.add(conditions.EndIfAction, group_id=gid)

    b.add(a.scripting.RepeatEndAction, group_id=repeat_id)
    return b.shortcut


def write_catalog_json(path: Path) -> None:
    payload = [entry.__dict__ for entry in CATALOG]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_catalog_markdown(path: Path) -> None:
    rows = [
        "# Talk to GIGI generated Shortcut catalog",
        "",
        "Generated by `scripts/shortcuts/build_talk_to_gigi.py --catalog-md artifacts/shortcuts/catalog.md`.",
        "",
        "| Command | Marker | Shortcut/native action | Status | Test phrase | Notes |",
        "|---|---|---|---|---|---|",
    ]
    for entry in CATALOG:
        rows.append(
            f"| `{entry.command_id}` | `{entry.marker}` | {entry.native_action} | {entry.status} | {entry.test_phrase} | {entry.notes} |"
        )
    rows.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(rows), encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the generated Talk to GIGI Shortcut")
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
