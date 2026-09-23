#!/usr/bin/env python3
"""Adds the actions of a Metadata.appintents to the app's own inside an IPA, in place.

  scripts/merge-appintents.py <ipa> <Payload/X.app/> <Metadata.appintents dir>

The system looks an intent up in the metadata of the bundle that runs it, and a LiveActivityIntent
runs in the app, so the widget's intents have to be listed in Spotify's file next to its own.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ipa, app_dir, ours = sys.argv[1:4]
member = f"{app_dir}Metadata.appintents/extract.actionsdata"
version = f"{app_dir}Metadata.appintents/version.json"

with zipfile.ZipFile(ipa) as z:
    theirs = json.loads(z.read(member)) if member in z.namelist() else None
with open(os.path.join(ours, "extract.actionsdata")) as f:
    added = json.load(f)

merged = added if theirs is None else {**theirs, "actions": {**theirs["actions"], **added["actions"]}}

with tempfile.TemporaryDirectory() as tmp:
    os.makedirs(os.path.join(tmp, os.path.dirname(member)))
    with open(os.path.join(tmp, member), "w") as f:
        json.dump(merged, f)
    entries = [member]
    if theirs is None:
        shutil.copy(os.path.join(ours, "version.json"), os.path.join(tmp, version))
        entries.append(version)
    subprocess.run(["zip", "-q", os.path.abspath(ipa), *entries], cwd=tmp, check=True)

print(f"    {len(added['actions'])} actions added to {len(merged['actions']) - len(added['actions'])} of the app's")
