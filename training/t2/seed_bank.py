#!/usr/bin/env python3
"""Seed bank for DOSE1 T2 generators (new in B1a; the old seed lists in seeds_public.py are unchanged).

Makes distinct, made-up messages from word banks per genre: chat, work, email, notes, technical,
ramble, slang (shorthand and stretched words). Typed seeds keep slang and shorthand as the
clean target. Dictation targets use complete compatible sentences, with optional
correction slots (CORR_*) that affect the input only.
Every slot used here is one the template engine in t2_common understands (NAME, NUM, DAY, DATE,
TIME, MONEY, EMAIL, DONT, NEG, URL, CORR_NUM, CORR_NAME, CORR_DAY).

No text here comes from Jordan's messages. Deterministic: the same seed gives the same list.

  python3 seed_bank.py --typed 700 --dictation 450 --seed 20261114
"""
from __future__ import annotations

import argparse
import random
import re
import sys
from typing import Dict, List

SEED = 20261114

Bank = Dict[str, List[str]]

TYPED: Dict[str, Bank] = {
    "chat": {
        "open": ["", "hey, ", "ok so ", "{NAME}, ", "honestly ", "btw ", "quick one: ", "so yeah, "],
        "subj": ["i", "we", "you", "{NAME}", "they", "the team", "my sister", "the landlord"],
        "act": ["can send", "might be late for", "wont make it to", "is free for", "asked about",
                "still owes me", "is picking up", "will bring", "forgot about", "is cooking for"],
        "obj": ["the thing", "dinner", "the bike", "the tickets", "the car keys", "the photos", "the cake",
                "the {NUM} boxes", "{MONEY} for the rent", "the new couch", "the parcel"],
        "tail": ["", " {DAY}", " at {TIME}", " tomorrow", " this weekend", " after work", " on {DATE}",
                 " when u get a sec"],
        "close": ["", ".", "?", "!", ", thanks", ", lmk", " lol", ", ok?"],
    },
    "work": {
        "open": ["", "hi {NAME}, ", "all, ", "quick update: ", "following up, ", "on the call, "],
        "subj": ["the client", "our vendor", "finance", "i", "we", "the design team", "legal", "the agency"],
        "act": ["wants the final", "signed off on", "pushed back on", "needs the revised", "approved",
                "moved the deadline for", "asked us to resend", "is still reviewing", "rejected the first draft of"],
        "obj": ["budget", "quote", "contract", "timeline", "slides", "brief", "invoice", "sow", "forecast",
                "onboarding plan", "pricing page", "q{NUM} numbers"],
        "tail": ["", " by {DAY}", " before the {DATE} call", " for {MONEY}", " this quarter", " ahead of the board"],
        "close": ["", ".", ".", "?", ", thanks", ", let me know"],
    },
    "email": {
        "open": ["hi {NAME},\n\n", "hello {NAME},\n\n", "hey {NAME},\n\n", "dear {NAME},\n\n"],
        "subj": ["thanks for the note about", "following up on", "i am writing about", "quick question on",
                 "just confirming", "sorry for the delay on"],
        "act": ["the order", "the booking", "your request", "the renewal", "the proposal", "the invoice dated {DATE}"],
        "obj": ["number {NUM}", "for {MONEY}", "at {URL}", "reference {NUM}", "ahead of {DAY}"],
        "tail": ["", ". please confirm by {DAY}", ". i will get back to you soon"],
        "close": ["\n\nbest,\n{NAME}", "\n\nthanks,\n{NAME}", "\n\nkind regards,\n{NAME}", "\n\nspeak soon,\n{NAME}"],
    },
    "notes": {
        "open": ["", "todo: ", "note to self: ", "reminder, ", "- "],
        "subj": ["call {NAME}", "book {NUM} rooms", "send {NAME} the file", "check {URL}", "ask {NAME} about",
                 "pay {MONEY}", "move the meeting to {TIME}", "re-read the {NUM} pages"],
        "act": ["", " and", ", then", " + "],
        "obj": ["ask about the invoice", "confirm the venue", "fix the typo in the header", "email the list",
                "buy milk and eggs", "renew the domain", "update the sheet", "bring the charger"],
        "tail": ["", " by {DAY}", " before {DATE}", " tonight"],
        "close": ["", "", ".", " (urgent)"],
    },
    "technical": {
        "open": ["", "fyi ", "so the ", "heads up, ", "pr note: "],
        "subj": ["the build", "the migration", "the cache", "the webhook", "the api", "the staging db", "the cron job"],
        "act": ["fails on", "times out after", "returns a 500 for", "needs a rerun for", "is green again after",
                "drops rows at", "logs a warning for"],
        "obj": ["the {NUM} retry", "the null check on {NAME}", "the {URL} endpoint", "the postgres index",
                "the iOS target", "the lint step", "the release branch", "the nightly export"],
        "tail": ["", " since {DAY}", " in prod", " on the {NUM}th run", " after the {DATE} deploy"],
        "close": ["", ".", ".", "?", " pls review"],
    },
    "ramble": {
        "open": ["so basically ", "ok so, um, ", "right so ", "the thing is, ", "honestly i was thinking "],
        "subj": ["we could maybe", "i think we should probably", "it might be nice to", "we should just",
                 "i kind of want to"],
        "act": ["move", "push", "reconsider", "rework", "simplify", "share"],
        "obj": ["the whole plan", "the pricing section", "the onboarding flow", "the {NUM} slides",
                "the launch date", "the team offsite"],
        "tail": [" and then see what {NAME} thinks", " and maybe loop in {NAME} too", " because the old one is a mess",
                 " and then i guess we wait until {DAY}", ", you know, and then go from there"],
        "close": [".", "."],
    },
    "slang": {
        "open": ["", "ngl ", "lowkey ", "tbh ", "omg "],
        "subj": ["that", "this", "ur idea", "the vibe", "ur message", "{NAME}"],
        "act": ["is so mid", "was insane", "is kinda cursed", "is lowkey perfect", "is giving chaos",
                "made me laugh", "is not it"],
        "obj": ["tbh", "rn", "fr", "for real", "no cap", "istg"],
        "tail": ["", " pls", " tmrw", " idk", " yk", " lol", " omg"],
        "close": ["", ".", "!", "!!", " haha", " lmao"],
    },
}

STRETCHED = ["sooo", "yeahhh", "nooo", "pleaseee", "heyyy", "soooo", "okkk", "coooool", "yesss", "hmmmm"]

# Dictation targets are already clean. Choose complete grammatical frames and
# compatible lexical slots, never independent subjects/auxiliaries/complements.
# Fillers and false starts are input-only operations in dictation_ops.
DICTATION_SEED_VERSION = "complete-compatible-frames-v1"
DICTATION_LEXICON: Bank = {
    "action": ["review", "update", "check", "revise", "finalize"],
    "past": ["reviewed", "updated", "checked", "revised", "finalized"],
    "item": ["the budget", "the draft", "the contract", "the schedule", "the checklist",
             "the proposal", "the timeline", "the invoice", "the report", "the project brief",
             "the delivery plan", "the cost estimate"],
    "countable": ["chairs", "boxes", "forms", "cables", "tickets", "printed copies"],
    "component": ["build", "cache", "webhook", "database migration", "nightly export", "indexer", "test suite"],
    "event": ["call", "workshop", "review meeting", "delivery", "site visit", "interview", "training session", "team briefing"],
    "first": ["book the venue", "reserve the meeting room", "confirm the hall booking", "check the venue address"],
    "second": ["send {NAME} the guest list", "email the agenda to {EMAIL}", "send the invitations", "print the registration forms"],
    "third": ["arrange {NUM} chairs", "order {NUM} lunch boxes", "pack the cables", "check the projector"],
}

DICTATION: Dict[str, List[str]] = {
    "prose": [
        "We should <action> <item> before {DAY}.",
        "I want to <action> <item> with {NAME}.",
        "We need to <action> <item> before {TIME}.",
        "It would be useful to <action> <item> before the <event>.",
        "Please <action> <item> and send the result to {EMAIL}.",
        "I will <action> <item> by {DAY}.",
        "Please ask {NAME} to <action> <item>.",
        "We can <action> <item> after the <event>.",
    ],
    "meeting": [
        "{NAME} agreed to <action> <item> by {DAY}.",
        "We decided to <action> <item> before the next <event>.",
        "The plan is to <action> <item> with {NAME}.",
        "Nobody has <past> <item> yet.",
        "{NAME} has <past> <item> and will report back at {TIME}.",
        "We have not <past> <item> since {DAY}.",
        "The team will <action> <item> before the <event> on {DATE}.",
        "The client asked us to <action> <item> before approving the change.",
    ],
    "list": [
        "First, <first>. Second, <second>. Third, <third>.",
        "Please complete these steps in order: First, <first>. Second, <second>. Third, <third>.",
        "For the <event>: First, <first>. Second, <second>. Third, <third>.",
        "Before {DAY}: First, <first>. Second, <second>. Third, <third>.",
    ],
    "correction": [
        "Order {CORR_NUM} <countable> for the <event>.",
        "We need {CORR_NUM} <countable> for the <event>.",
        "The corrected order is for {CORR_NUM} <countable>.",
        "Schedule the <event> for {CORR_DAY}.",
        "Move the <event> to {CORR_DAY}.",
        "The <event> is on {CORR_DAY} at {TIME}.",
        "Copy {CORR_NAME} on the email about <item>.",
        "Ask {CORR_NAME} to <action> <item>.",
        "Please send <item> to {CORR_NAME}.",
        "The contact for the <event> is {CORR_NAME}.",
    ],
    "technical": [
        "The <component> failed after {NUM} retries.",
        "The <component> has been failing since the {DATE} deployment.",
        "The <component> is still failing in production.",
        "The <component> needs another test on the staging server.",
        "Please check the <component> logs before restarting the service.",
        "Do not restart the <component> until {NAME} approves the change.",
        "The documentation for the <component> is available at {URL}.",
        "Send the <component> incident report to {EMAIL}.",
        "The <component> returned an error for requests to {URL}.",
        "We will test the <component> again after the <event>.",
    ],
    "ramble": [
        "We could <action> <item>, but the client has not approved the change.",
        "I think we should probably <action> <item> before {DAY}.",
        "It might be useful to <action> <item> with {NAME}.",
        "We might <action> <item> after the <event>, but that is not confirmed.",
        "I am not sure whether we need to <action> <item> before {DATE}.",
        "I may be able to <action> <item>, but I cannot promise a completion date.",
        "I would prefer to <action> <item> before the <event>.",
        "We have not decided whether to <action> <item> yet.",
    ],
    "numbers": [
        "We need {NUM} <countable> for the <event>.",
        "The order contains {NUM} <countable>.",
        "Please reserve {NUM} <countable> for {NAME}.",
        "The supplier has confirmed {NUM} <countable> for the <event>.",
        "We have counted {NUM} <countable> in the delivery.",
        "Please record {NUM} <countable> on the inventory sheet.",
        "The budget for the <event> is {MONEY}.",
        "The total cost is {MONEY}, excluding delivery.",
        "The booking is for {DATE} at {TIME}.",
        "Please send the invoice for {MONEY} to {EMAIL}.",
        "The <event> starts at {TIME} on {DATE}.",
    ],
    "negation": [
        "We {NEG} <action> <item> before {NAME} signs the approval.",
        "I {DONT} want to <action> <item> today.",
        "Nobody should send <item> to the client before {DAY}.",
        "Do not send {MONEY} until {NAME} confirms the invoice.",
        "Do not open {URL} on the production server.",
        "We must not <action> <item> while the review is still open.",
        "Nobody has permission to <action> <item> yet.",
        "The client has not approved <item> for release.",
        "The file at {URL} is not ready for release.",
        "The booking is not confirmed for {DATE}.",
        "We do not need to <action> <item> before the <event>.",
        "Please do not <action> <item> until the <event> has ended.",
    ],
}

# Continuations are complete, explicit requests, not dangling filler/modality.
# Their repeated capitalized slots remain independently sampled protected facts.
DICTATION_CONTINUATIONS = {
    "default": ["", "Please send a status update to {EMAIL}.", "Please keep this message with the project records.",
                "Please record these details in the project notes.", "Please keep a written record of these details.",
                "Please ask {NAME} to acknowledge this message.", "Please reply when you have read this message.",
                "Please send a confirmation email to {EMAIL}.", "Please add this message to the project log."],
    "list": ["", "Please keep these steps in this order.", "Complete all three steps before {DAY}.",
             "Please confirm completion with {NAME}.", "Please send the checklist to {EMAIL}.",
             "Keep a record of each completed step.", "Please flag any step that cannot be completed.",
             "Please check the final setup before the <event>.", "Please record the result in the notes."],
}


def _compose_dictation(genre: str, rng: random.Random) -> str:
    frame = rng.choice(DICTATION[genre])
    continuation = rng.choice(DICTATION_CONTINUATIONS.get(genre, DICTATION_CONTINUATIONS["default"]))
    text = frame + (" " + continuation if continuation else "")
    values = {}
    for key in re.findall(r"<([a-z_]+)>", text):
        if key not in values:
            values[key] = rng.choice(DICTATION_LEXICON[key])
    text = re.sub(r"<([a-z_]+)>", lambda match: values[match.group(1)], text)
    if re.search(r"<[a-z_]+>", text):
        raise ValueError("unresolved dictation lexical slot")
    return text



def _join(parts: List[str]) -> str:
    """Join bank pieces with single spaces. Punctuation and new lines attach to the piece before them."""
    out = ""
    for p in parts:
        if not p:
            continue
        if not out or out.endswith("\n"):
            out += p.lstrip(" ")
        elif p[0] in ".,?!;:\n":
            out += p
        elif p.startswith(" "):
            out += p
        else:
            out += " " + p
    return re.sub(r"[ ]{2,}", " ", out).strip(" ")


def _compose(bank: Bank, rng: random.Random) -> str:
    parts = [rng.choice(bank[k]) for k in ("open", "subj", "act", "obj", "tail", "close") if k in bank]
    return _join(parts)


def _stretch(text: str, rng: random.Random) -> str:
    if rng.random() < 0.35:
        return rng.choice(STRETCHED) + " " + text
    return text


def typed_templates(n: int, seed: int = SEED) -> List[str]:
    """n distinct typed seed templates (clean target text, shorthand and slang kept)."""
    rng = random.Random(f"typed-seeds:{seed}")
    genres = list(TYPED)
    out: List[str] = []
    seen = set()
    guard = 0
    while len(out) < n:
        guard += 1
        if guard > n * 200:
            raise RuntimeError("seed space exhausted")
        g = genres[len(out) % len(genres)]
        t = _stretch(_compose(TYPED[g], rng), rng) if g == "slang" else _compose(TYPED[g], rng)
        if g != "slang" and rng.random() < 0.6:
            t = _sentence_case(t, rng, 0.0)
        key = t.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
    return out


def _sentence_case(text: str, rng: random.Random, final_punct_share: float) -> str:
    """Capital first letter and standalone i; add a final full stop for most rows (the dictation ops remove it on 27% of rows)."""
    text = re.sub(r"\bi\b", "I", text)
    if text and text[0].isalpha():
        text = text[0].upper() + text[1:]
    if text and (text[-1].isalnum() or text[-1] == "}") and rng.random() < final_punct_share:
        text += "."
    return text


def dictation_templates(n: int, seed: int = SEED) -> List[str]:
    """n distinct already-clean complete sentence templates with protected/correction slots.

    Templates with a correction slot (CORR_*) are kept in their own pool; gen_dictation_v2 draws them at the
    measured 3.4% of rows, so most rows have no self-correction."""
    rng = random.Random(f"dictation-seeds:{seed}")
    genres = list(DICTATION)
    out: List[str] = []
    seen = set()
    guard = 0
    while len(out) < n:
        guard += 1
        if guard > n * 200:
            raise RuntimeError("seed space exhausted")
        g = genres[len(out) % len(genres)]
        t = _compose_dictation(g, rng)  # corruption operators modify the input only
        key = t.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
    return out


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--typed", type=int, default=700)
    ap.add_argument("--dictation", type=int, default=450)
    ap.add_argument("--seed", type=int, default=SEED)
    args = ap.parse_args(argv)
    t = typed_templates(args.typed, args.seed)
    d = dictation_templates(args.dictation, args.seed)
    print(f"typed templates: {len(t)} distinct; dictation templates: {len(d)} distinct")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
