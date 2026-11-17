# Osupa Collector

A small Windows script that packs your **osu!standard replays** and the **.osu map files** they were played on into zip files, so you can send them to the osu!PA research project by FFA2008.

## Download

Download **[Osupa Collector v1.5.zip](Osupa%20Collector%20v1.5.zip)** (click it, then the download button (top right corner)), unzip it, and double-click `osupa_collect.bat`. Full steps are in [READ ME.txt](READ%20ME.txt).

## What it does

- Reads your osu! lazer and/or stable folders. It **never changes, moves or deletes** anything in them.
- Takes only osu!standard replays and the .osu files of maps you have replays on: no audio, backgrounds, skins, settings, collections, account data or passwords.
- Asks 6 optional questions about your setup, including your screen resolution and refresh rate.
- Shows how your data is used and asks you to agree first: [DATA USE.txt](DATA%20USE.txt).
- When it's done, it opens the upload page (a Google Form) with your osu! name filled in. Nothing is uploaded unless you do it yourself.

## Check it yourself

Everything it does is in [osupa_collect.ps1](osupa_collect.ps1), with comments. Open it in Notepad. `osupa_collect.bat` only starts it.
It does not use the osu! website or API, and it is not made by or connected to ppy / osu!.
