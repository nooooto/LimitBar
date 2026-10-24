// LimitBar widget — mostra sull'iPhone i limiti che LimitBar (sul Mac) salva su iCloud Drive.
// LimitBar lo installa da sola nella cartella iCloud di Scriptable: non serve modificarlo.
// Widget piccolo: solo la finestra principale; medio e grande: 5 ore e settimana;
// schermata di blocco (rettangolare): una riga per servizio.
// Piccolo e medio mostrano i primi due servizi (non ce ne stanno di più), il grande tutti.

const COLORS = {
  claude: new Color("#D97857"),
  codex: new Color("#6B66F7"),
  opencode: new Color("#EC4899"),
}
const DANGER = new Color("#FF453A")
const TEXT = Color.white()
const SECONDARY = new Color("#FFFFFF", 0.62)
const TRACK = new Color("#FFFFFF", 0.16)

const fm = FileManager.iCloud()
const dataPath = fm.joinPath(fm.documentsDirectory(), "limitbar.json")

async function loadData() {
  if (!fm.fileExists(dataPath)) return null
  await fm.downloadFileFromiCloud(dataPath)
  return JSON.parse(fm.readString(dataPath))
}

// Once the reset time has passed the window is empty, even if the Mac hasn't updated yet.
function percent(win, now) {
  if (!win) return null
  if (win.resetsAt && new Date(win.resetsAt) <= now) return 0
  return Math.max(0, Math.min(100, Math.round(win.usedPercent)))
}

function formatter(pattern) {
  const f = new DateFormatter()
  f.locale = "it_IT"
  f.dateFormat = pattern
  return f
}
const TIME = formatter("HH:mm")
const DAY_TIME = formatter("EEE HH:mm")
const DATE = formatter("d MMM")

function resetText(win, now) {
  if (!win || !win.resetsAt) return ""
  const date = new Date(win.resetsAt)
  if (date <= now) return "azzerato"
  const sameDay = date.toDateString() === now.toDateString()
  if (sameDay) return "reset " + TIME.string(date)
  if (date - now >= 6 * 86400 * 1000) return "reset " + DATE.string(date)
  return "reset " + DAY_TIME.string(date)
}

function ago(iso, now) {
  if (!iso) return "nessun dato"
  const seconds = (now - new Date(iso)) / 1000
  if (seconds < 60) return "adesso"
  if (seconds < 3600) return Math.floor(seconds / 60) + " min fa"
  if (seconds < 86400) return Math.floor(seconds / 3600) + " h fa"
  return Math.floor(seconds / 86400) + " g fa"
}

/// Name for a window that isn't what its column says, e.g. a 30-day limit under "Settimana".
function periodLabel(win, expectedMinutes) {
  if (!win || !win.windowMinutes) return null
  const minutes = win.windowMinutes
  if (Math.abs(minutes - expectedMinutes) <= expectedMinutes / 10) return null
  if (minutes < 24 * 60) return Math.round(minutes / 60) + " ore"
  if (minutes >= 28 * 24 * 60 && minutes <= 31 * 24 * 60) return "mese"
  return Math.round(minutes / (24 * 60)) + " giorni"
}

function barImage(value, color, width, height) {
  const ctx = new DrawContext()
  ctx.size = new Size(width, height)
  ctx.opaque = false
  ctx.respectScreenScale = true
  const radius = height / 2
  const track = new Path()
  track.addRoundedRect(new Rect(0, 0, width, height), radius, radius)
  ctx.addPath(track)
  ctx.setFillColor(TRACK)
  ctx.fillPath()
  if (value > 0) {
    const fill = new Path()
    fill.addRoundedRect(new Rect(0, 0, Math.max(height, width * value / 100), height), radius, radius)
    ctx.addPath(fill)
    ctx.setFillColor(value >= 90 ? DANGER : color)
    ctx.fillPath()
  }
  return ctx.getImage()
}

function addText(stack, text, size, color, weight) {
  const t = stack.addText(text)
  t.font = weight === "bold" ? Font.semiboldSystemFont(size) : Font.systemFont(size)
  t.textColor = color
  t.lineLimit = 1
  return t
}

/// One usage window: "72% usato", the bar, the reset time.
function addWindow(stack, win, color, width, now, label, expectedMinutes) {
  const column = stack.addStack()
  column.layoutVertically()
  column.size = new Size(width, 0)
  const value = percent(win, now)
  if (value === null) {
    addText(column, label, 10, SECONDARY)
    addText(column, "nessun limite", 11, SECONDARY)
    return
  }
  const period = periodLabel(win, expectedMinutes)
  // Label and percentage share a line so two services fit in a medium widget.
  const line = column.addStack()
  line.centerAlignContent()
  addText(line, period ? label + " · " + period : label, 10, SECONDARY)
  line.addSpacer()
  addText(line, value + "%", 13, TEXT, "bold")
  column.addSpacer(3)
  const bar = column.addImage(barImage(value, color, width, 5))
  bar.imageSize = new Size(width, 5)
  column.addSpacer(3)
  addText(column, resetText(win, now), 9, SECONDARY)
}

function addProvider(widget, provider, family, now) {
  const color = COLORS[provider.id] || TEXT
  const header = widget.addStack()
  header.centerAlignContent()
  addText(header, provider.name, 13, color, "bold")
  if (provider.plan && family !== "small") {
    header.addSpacer(6)
    addText(header, provider.plan, 10, SECONDARY)
  }
  header.addSpacer()
  addText(header, ago(provider.updatedAt, now), 9, SECONDARY)
  widget.addSpacer(4)

  const row = widget.addStack()
  if (family === "small") {
    // The window that runs out first is the one worth seeing on a small widget.
    const main = provider.fiveHour || provider.week
    addWindow(row, main, color, 120, now, provider.fiveHour ? "5 ore" : "Settimana",
              provider.fiveHour ? 300 : 10080)
  } else {
    const width = 135
    addWindow(row, provider.fiveHour, color, width, now, "5 ore", 300)
    row.addSpacer()
    addWindow(row, provider.week, color, width, now, "Settimana", 10080)
  }
}

function lockScreenWidget(data, now) {
  const widget = new ListWidget()
  for (const provider of data.providers) {
    const value = percent(provider.fiveHour || provider.week, now)
    const t = widget.addText(provider.name + "  " + (value === null ? "–" : value + "%"))
    t.font = Font.semiboldSystemFont(13)
  }
  return widget
}

function buildWidget(data, family) {
  const now = new Date()
  if (data && family === "accessoryRectangular") return lockScreenWidget(data, now)

  const widget = new ListWidget()
  const gradient = new LinearGradient()
  gradient.colors = [new Color("#1E1B2E"), new Color("#2B2256")]
  gradient.locations = [0, 1]
  widget.backgroundGradient = gradient
  widget.setPadding(12, 14, 12, 14)

  if (!data) {
    addText(widget, "LimitBar", 15, TEXT, "bold")
    widget.addSpacer(6)
    addText(widget, "Nessun dato: apri LimitBar sul Mac.", 11, SECONDARY)
    return widget
  }

  const providers = family === "large" ? data.providers : data.providers.slice(0, 2)
  providers.forEach((provider, index) => {
    if (index > 0) widget.addSpacer(family === "small" ? 8 : 10)
    addProvider(widget, provider, family, now)
  })
  widget.addSpacer()
  // The Mac rewrites the file every few minutes; check back on a similar rhythm.
  widget.refreshAfterDate = new Date(Date.now() + 5 * 60 * 1000)
  return widget
}

const data = await loadData()
const family = config.widgetFamily || "medium"
const widget = buildWidget(data, family)
if (config.runsInWidget) {
  Script.setWidget(widget)
} else {
  await widget.presentMedium()
}
Script.complete()
