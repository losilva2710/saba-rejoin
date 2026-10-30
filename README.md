# ⚡ Saba Rejoin

**Roblox auto rejoin** tool for **Termux** on **rooted** Android phones and cloud phones.
Supports multiple Roblox apps at once (original + clones) with an easy menu in **English** or **Vietnamese**.

---

## ✨ Features

- 🔄 **Auto rejoin** when the game crashes, is closed, gets kicked or shows the *Disconnected* screen
- ⏱️ **Periodic kill + rejoin** every N minutes
- 📱 **Multiple Roblox apps** — choose which apps to run, one shared link or a different server per app
- 🔑 **Login via cookie** — log your own accounts into each app with your `.ROBLOSECURITY` cookie (single or from a file), check which account each app is using
- 🔗 Accepts **Place ID, game link, private server link, share link** (`roblox.com/share?code=...`)
- 🛡️ **Anti rejoin loop** — after repeated failures, waits longer each time (1 → 2 → 4 ... up to 30 min)
- 💬 **Discord notifications** via webhook (crash, kick, rejoin, low RAM...)
- 🧠 **RAM monitor** — warns when the device is running out of memory
- 🌙 **Run schedule** — e.g. only run from 22:00 to 08:00
- 🚀 **Auto start on boot** (Magisk / KernelSU / Termux:Boot) — optional
- ⬆️ **Update from the menu** directly from this repo
- 🔍 **Runs in background** — keeps working after you close Termux
- 🌐 **English / Tiếng Việt** — switch anytime from the menu

## 📋 Requirements

- Android 10 or newer, **rooted** (Magisk / KernelSU / cloud phone with root)
- **Termux** app (from F-Droid or GitHub — not the old Play Store version)
- Each Roblox app logged in to its account (manually, or with **Login via cookie**)

## 📥 Install

Open Termux and paste **one command**:

```bash
bash <(curl -sL https://raw.githubusercontent.com/losilva2710/saba-rejoin/main/install_rejoin.sh)
```

The installer checks root, installs the required packages and opens the menu.
On first run, Magisk/KernelSU asks for root permission for Termux → tap **Grant** (choose *forever*).

## ▶️ Usage

Open the menu:

```bash
rejoin
```

On first launch you choose the language (English / Tiếng Việt). Then:

1. **3 → Apps & server** — select Roblox apps and paste the server link
2. **6 → Settings** — adjust kill + rejoin time, kick detection... (optional)
3. **1** — start auto rejoin

### Menu

```
⚡ Saba Rejoin
● Running  · 3 app  · RAM 2140/4000 MB
Kick: On  Kill: 30m  Hours: all day  Discord: ✔
──────────────────────────────
 1  Stop auto rejoin
 2  View log
 3  Apps & server
 4  Accounts (cookie)
 5  Discord
 6  Settings
 7  Update tool
 0  Exit (keeps running)
```

| Item | Inside |
|---|---|
| 1 | Start / stop auto rejoin (runs in background) |
| 2 | Live log (Ctrl+C to go back) |
| 3 · Apps & server | Select apps & assign link · Select all (one link) · List selected · Open all · Close all |
| 4 · Accounts | Log in one app (paste cookie) · Log in many from a file · Show account of each app · Log out |
| 5 · Discord | Set webhook · Send test · Rename device · Remove |
| 6 · Settings | Timing, kick, anti-loop, RAM · Run schedule · Auto start on boot · Test kick detection · Language |
| 7 | Update from this repo |

## 🔑 Login via cookie

1. Open each Roblox app **once** (up to the login screen) so it creates its data
2. **4 → Accounts**, then:
   - **Log in one app** — pick an app, paste a `.ROBLOSECURITY` cookie (input is hidden)
   - **Log in many from a file** — put cookies in `/sdcard/Download/cookies.txt` (**one per line**), pick apps in order: line 1 → 1st app, line 2 → 2nd app...
3. The tool checks each cookie with Roblox and shows the **account name** before logging in
4. **Show account of each app** tells you which account each app is using

What happens to your cookie:

- Sent **only to Roblox** (`users.roblox.com`) to check it, then written into that Roblox app's own cookie storage
- **Never** saved by the tool, never written to the log, never sent to Discord or anywhere else
- After a file login the tool offers to **delete the cookie file**

> ⚠️ A `.ROBLOSECURITY` cookie gives **full access** to the account. Only use your own cookies, never share them, and never paste them into tools you can't read.
> Roblox may invalidate a cookie used from a very different IP/region — if login doesn't stick, log in normally once on that device.

## 🔍 How kick detection works

The tool **does not read the screen**. For each app it checks:

1. **Roblox log** — a disconnect line appears → rejoin immediately
2. **Game server connection** — while in game, Roblox keeps a UDP connection to the server. When kicked, the connection is gone → after 60 seconds (adjustable) it rejoins

Use **Settings → Test kick detection** to verify on your device: in game `UDP game > 0`, after a kick it drops to `0`.

## ⚙️ Default settings

| Setting | Default |
|---|---|
| Check every | 15 seconds |
| Wait for game to load | 30 seconds |
| Periodic kill + rejoin | Off |
| Rejoin on kick | On (after 60 s without connection) |
| Back off after | 3 failures in a row |
| Low RAM warning below | 500 MB |
| Run hours | All day |

Slow device / many clones → raise **wait for game to load** (Settings → Timing) to 60 seconds.

## 📁 Files

| Path | Content |
|---|---|
| `~/rejoin/rejoin.sh` | Main script |
| `~/rejoin/config.conf` | Settings |
| `~/rejoin/links.conf` | Server link for each app |
| `~/rejoin/rejoin.log` | Log |

Your webhook and server links are stored only on your device, **not** in this repo.

## 🗑️ Uninstall

```bash
rejoin-uninstall
```

## ⚠️ Notes

- The tool never asks for passwords and never extracts or exports cookies. Cookies are only used when **you** paste your own (Accounts menu).
- AFK farming / auto rejoin may go against Roblox's Terms of Use. Use at your own risk.
- Only install from this repo. Never run `curl ... | bash` commands from unknown sources with root.
