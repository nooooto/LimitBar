# LimitBar

Your Claude and OpenCode Go usage limits in the Mac menu bar.

*[Leggi in italiano](README.it.md)*

LimitBar is a small native macOS app. It shows how much of each limit you've used and when it resets. It also tells you whether your pace will last until the reset, what your work would have cost at API prices, and whether the services are having trouble. The app is in English and Italian, following your Mac's language.

> LimitBar is an independent project. It isn't made by, affiliated with or endorsed by Anthropic or OpenCode.

## What it shows

- **Limits.** One ring per limit (5 hours and week, plus the month for OpenCode Go), with the time until each resets. The number in the menu bar turns orange at 80% and red at 90%. When a limit is used up, the menu bar shows how long until it's back.
- **Pace.** On the week and the month, a tick marks where you'd be if you used the limit evenly until it resets. A line under the ring says *On track*, *12% ahead* or *12% to spare*. For the 5 hours, a forecast warns you when the current pace would use the limit up before the reset.
- **Service status.** LimitBar reads Anthropic's and OpenCode's status pages every 5 minutes. If Claude Code, the API, claude.ai, OpenCode Go or the model you're using has trouble, an orange or red strip appears in the panel and a dot appears on the menu bar icon.
- **Value at API prices.** What the work you did with Claude Code and OpenCode would have cost at public API prices this month, compared with your plan and with last month, broken down by project.
- **Spending window.** Click the value card to open it. It covers Today, 7 days, 30 days or This month, with a day-by-day chart by service, tokens, models and projects. Amounts are in US dollars or euros (at the ECB's daily rate), as chosen in Settings.
- **Activity.** A service's icon takes its colour while its agent is working. A notification tells you when Claude or OpenCode finishes a long job or is waiting for you. Every Monday you get a summary of the week before.
- **iPhone widget** (optional). LimitBar copies your limits to iCloud Drive for a [Scriptable](https://scriptable.app) widget, which it installs by itself in Scriptable's folder.

## Requirements

- A Mac with Apple silicon, running macOS 14 or later. It's designed for macOS 26 and 27, with Liquid Glass.
- Claude: a Pro or Max plan, used with Claude Code or signed in from the panel.
- OpenCode Go: the OpenCode app, with Go connected.

## Install

1. Download `LimitBar.dmg` from [Releases](../../releases) and open it.
2. In the window that appears, drag LimitBar onto the Applications folder, then open it from Applications. LimitBar isn't notarized by Apple, so the first time macOS says it can't verify the developer. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You can also run this in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/LimitBar.app
   ```
3. Click the icon in the menu bar to open the panel. Allow notifications when macOS asks.

There's also `LimitBar.zip` in the release: Safari unzips it for you after downloading, so you'll find LimitBar in your Downloads folder, ready to drag to Applications.

### Build from source

You only need the Command Line Tools, not Xcode:

```bash
xcode-select --install
./build.sh --install
```

`./build.sh --install` builds `build/LimitBar.app`, copies it to `~/Applications` and opens it. It also installs the Claude Code status line and hook scripts, which LimitBar uses to read your limits and activity from Claude Code. To use them, add them to `~/.claude/settings.json` (see [scripts/](scripts)).

Run the tests with `swift test`.

## Connecting the services

- **Claude.** If you use Claude Code with your account, LimitBar finds its sign-in. You don't need to do anything. Otherwise, click **Sign in to Claude…** in the panel, approve in the browser, copy the code it shows and click **Paste code**.
- **OpenCode Go.** OpenCode doesn't expose its limits, so LimitBar estimates them from the use recorded on this Mac in OpenCode's database. Connect Go in the OpenCode app, then choose your plan (Go or Go Plus) in Settings. Use from other devices isn't counted.

## Privacy

LimitBar has no server of its own and collects nothing. It only connects to:

- Anthropic's usage endpoint, to read your Claude limits with your own sign-in;
- the status pages `status.claude.com` and `status.opencode.ai` (this can be turned off in Settings);
- the European Central Bank's daily rate, when amounts are shown in euros.

Everything else is read from files on your Mac: Claude Code's and Codex's logs, and OpenCode's database. If you have iCloud Drive, a copy of your limits goes to its LimitBar folder for the widget.

**About Claude sign-in.** Claude doesn't offer a public API for plan limits. LimitBar uses the same sign-in and usage endpoint as Claude Code. Anthropic may change these at any time.

## License

[MIT](LICENSE)

## A note from the developer

LimitBar started as a personal project, and I built it entirely with Claude Code. I thought it might be useful to someone else, so I decided to publish it, without any great ambitions. I'm not a particularly talented or experienced developer: if you find problems or weak spots, feel free to [report them](../../issues) or fix them yourself with a pull request.
