import std/[
  strformat,
  strutils,
  sequtils,
  logging,
  colors,
  with,
  os
]

from std/htmlgen import small, a, b

putEnv("GSETTINGS_SCHEMA_DIR", "../share/glib-2.0/schemas")

import gintro/[gtk4, gdk4, gobject, gio, glib]
import govee

const 
  License     = staticRead("LICENSE")
  GtkVersion  = [gtk4.MAJOR_VERSION, gtk4.MINOR_VERSION, gtk4.MICRO_VERSION].join "."
  GLibVersion = [glib.MAJOR_VERSION, glib.MINOR_VERSION, glib.MICRO_VERSION].join "."

var logger = newConsoleLogger(fmtStr="$appname [$levelname] ", useStderr=true)
addHandler logger

template `margin=`(widget: Widget; margin: int) = widget.setMargin margin
proc newLabelWithMarkup(text: string): Label =
  result = newLabel(text)
  result.useMarkup = true 

# ----- Device Button -----

type
  DeviceButton = ref object of Button
    id: int
    device: GoveeDevice
    govee: Govee

when defined(gcDestructors):
  proc `=destroy`*(x: var typeof(DeviceButton()[])) =
    gtk4.`=destroy`(typeof(Button()[])(x))

proc newDeviceButton*(
  device: GoveeDevice; 
  govee: Govee; 
  id: int
): DeviceButton =  
  let
    vbox   = newBox(Orientation.vertical)

    idl    = newLabelWithMarkup(small(fmt"Device #{id}"))
    namel  = newLabelWithMarkup(b(device.name))
    modell = newLabelWithMarkup(small(device.model))
    addrl  = newLabelWithMarkup(small(device.address))

  result = newButton(DeviceButton) 

  for label in [idl, namel, modell, addrl]: vbox.append label 

  result.child = vbox

  result.id = id
  result.device = device
  result.govee = govee

# ----- Error Dialog -----
type
  ErrorDialog = ref object of Dialog
    err: ref Exception

when defined(gcDestructors):
  proc `=destroy`*(x: var typeof(ErrorDialog()[])) =
    gtk4.`=destroy`(typeof(Dialog()[])(x))

proc newErrorDialog(error: ref Exception; quitAfter: bool = false): ErrorDialog = 
  proc resp_cb(d: ErrorDialog; id: int; QA: bool) = 
    d.destroy()

    if QA: 
      quit -1


  result = newDialog(ErrorDialog)

  with result:
    err = error

    title = "Error"
    margin = 10

    connect("response", resp_cb, quitAfter)

  with result.contentArea:
    append newLabel("We've encountered an error:")
    append newLabel(cstring error.msg)

  let okBtn = result.addButton("OK", ord ResponseType.ok)
  okBtn.margin = 5

# ------ Signal Recivers ------

proc abt(_: SimpleAction, v: Variant, window: ApplicationWindow) = 
  let dia = newAboutDialog()
  let logo = newImageFromFile("./icons/logo.png")

  with dia:
    transientFor = window

    authors           = "Grace"
    documenters       = "Grace"
    logo              = logo.paintable
    comments          = "This application is in no way, shape, or form affiliated with Govee."
    copyright         = "(C) 2022 Grace"
    license           = License
    licenseType       = gtk4.License.custom
    programName       = "Govee For Desktop"
    systemInformation = cstring fmt"""
      OS      {hostOS.capitalizeAscii()}
      CPU    {hostCPU}

      System libraries
      {'\t'}Gtk      {GtkVersion}
      {'\t'}GLib    {GLibVersion}

      Nim {NimVersion}
      """.dedent
    version           = "0.1.0"
    website           = "https://github.com/nonimportant"
    websiteLabel      = "My Github"

  debug "Showing About Dialog..."
  show dia

proc logout(_: Button) =
  info "Logging out, removing KEY file and exiting application."
  removeFile ".KEY"
  quit 0

proc search(entry: SearchEntry, data: tuple[buttons: seq[DeviceButton]]) = 
  for button in data.buttons:
    if entry.text notin $button.device:
      #debug "Search text does not match device name \"", button.device, "\". Hiding button."
      button.hide()
    else:
      #debug "Search text DOES match device name \"", button.device, "\". Showing button."
      button.show()

proc save(
  _: Button; 
  data: tuple[
    btn: DeviceButton;
    bslider, tempslider: Scale, 
    colorbtn: ColorButton;
    tbtn: ToggleButton;
    win: Window;
    initTemp: float
  ]
) =
  let
    acc               = data.btn.govee
    device            = data.btn.device
  
    colorBtn          = data.colorbtn
    brightnessSlider  = data.bslider
    powerSwitch       = data.tbtn
    temperatureSlider = data.tempslider
  
  let
    color = rgb(
      int colorBtn.getRgba().red * 255, # RGB values in GTK are divided by 255, for some reason
      int colorBtn.getRgba().green * 255, 
      int colorBtn.getRgba().blue * 255 
    )
    brightness  = brightnessSlider.value
    power       = powerSwitch.active
    temperature = temperatureSlider.value

  var 
    info: tuple[
      online: bool, 
      powerState: bool, 
      brightness: float, 
      colorTemp: int,
      color: Color
    ] 

  try: 
    info = acc.getInfo(device) 
  except Exception as err:
    let errDia = newErrorDialog(err)
    errDia.transientFor = data.win
    errDia.show()

    return
      
  if color != info.color:
    # if the color has changed, set it to the device
    info "Changing ", device, "'s color to ", color
    acc.setColor(device, color)
  elif temperature != data.initTemp:
    # ditto
    info "Changing ", device, "'s color temperature to ", int temperature
    acc.setColorTemp(device, int temperature) 

  # * NOTE: This gives the color precedence if both have changed

  if brightness != info.brightness * 100:
    # ditto
    info "Changing ", device, "'s brighness to ", int(brightness) / 100
    acc.setBrightness(device, brightness / 100)

  if power != info.powerState:
    # ditto
    info "Changing ", device, "'s power state to ", if power: "on" else: "off"
    acc.turn(device, power)

  data.win.close()

# ----- Device Window -----

proc deviceWindow(button: DeviceButton) =
  debug "Opening window for device #", button.id, ", ", button.device.name

  # --- Window ---
  let
    window = newWindow()
    grid   = newGrid()

  # --- govee ---
  let
    device = button.device
    id     = button.id
    acc    = button.govee

  var
    info: tuple[
      online: bool, 
      powerState: bool, 
      brightness: float, 
      colorTemp: int,
      color: Color
    ] 

  try: 
    info = acc.getInfo(device) 
  except Exception as err:
    let errDia = newErrorDialog(err)
    errDia.transientFor = window
    errDia.show()

    quit QuitFailure
    
  # --- header bar ---
  let headerBar  = newHeaderBar()

  headerBar.titleWidget = newLabelWithMarkup(
    b(fmt"{device.name}  ") & small(fmt"Device #{id}")
  )
  window.titleBar = headerBar

  # --- UI ---
  # color
  var color: gdk4.RGBA
  discard color.parse(cstring $info.color) # set the RGBA color 
  # to the device's color

  let colorBtn = newColorButtonWithRgba(color) 
  colorBtn.setMargin(5)

  # brightness
  let brightnessSlider = newScale(
    Orientation.horizontal, 
    newAdjustment(cdouble info.brightness * 100, 1, 101, 1, 5)
  )

  brightnessSlider.drawValue = true

  # power
  let powerSwitch = newToggleButton()
  powerSwitch.active = info.powerState

  proc switch(toggle: ToggleButton) = 
    toggle.label = cstring(
      if toggle.active: "ON"
      else: "OFF"
    )

  powerSwitch.switch()
  powerSwitch.connect("clicked", switch)

  # color temp
  let temperatureSlider = newScale(
    Orientation.horizontal,
    newAdjustment(cdouble info.colorTemp, 2000, 9001, 1, 100)
  )

  temperatureSlider.drawValue = true

  # save btn
  let saveBtn = newButton("Save")
  saveBtn.connect(
    "clicked", 
    save, 
    (
      button, 
      brightnessSlider, 
      temperatureSlider, 
      colorBtn, 
      powerSwitch, 
      window, 
      temperatureSlider.value
    )
  )

  # --- Setting up grid ---
  with grid:
    setMargin 15

    hexpand = true
    columnHomogeneous = true
    #rowHomogeneous = true

    # -- Attach widgets to grid --
    attach(newLabel("Color:"), 0, 0)
    attach(colorBtn, 1, 0)

    attach(newLabel("Brightness:"), 0, 1)
    attach(brightnessSlider, 1, 1)

    attach(newLabel("Power:"), 0, 2)
    attach(powerSwitch, 1, 2)

    attach(newLabel("Color Temperature:"), 0, 3)
    attach(temperatureSlider, 1, 3)

    attach(saveBtn, 0, 4, 2) # col 0, row 2 with a col-span of 2

  window.child = grid
  window.resizable = false
  window.show()

# ----- Main Window -----

proc openWindow(_: Dialog; x: int; window: ApplicationWindow) =
  debug "Opened main window"
  let apiKey = readFile(".KEY") 

  var acc: Govee

  try:
    acc = initGovee(apiKey)
  except GoveeAuthorizationError as err:
    removeFile(".KEY")
    fatal "API key \"", apiKey, "\" is invalid"
    
    let errDia = newErrorDialog(err, quitAfter=true)
    errDia.transientFor = window

    errDia.show()
    return
   
  let settings = window.getSettings()

  window.defaultSize = (width: 700, height: 600)
  window.title       = "Govee For Desktop"

  let 
    headerBar = newHeaderBar()

  headerBar.titleWidget = newLabelWithMarkup(b(window.title, "  ") & small"0.1.0")
  window.titlebar       = headerBar

  # searchBar
  let
    searchBar    = newSearchBar()
    searchEntry  = newSearchEntry()    
    searchButton = newToggleButton()

  searchButton.iconName = "system-search-symbolic"

  discard searchButton.bindProperty(
    "active",
    searchBar,
    "search-mode-enabled",
    {bidirectional}
  )

  searchEntry.halign = Align.center 

  with searchBar:
    hexpand          = true
    keyCaptureWidget = window
    showCloseButton  = true
    connectEntry       searchEntry
    setChild           searchEntry

  let 
    menuBtn = newMenuButton()
    logoutBtn = newButtonFromIconName("system-log-out-symbolic")

  menuBtn.iconName = "open-menu-symbolic"

  # ---- Menu ----
  let 
    menu = newMenu()
    themeMenu = newMenu()

    inspectorAct = newSimpleAction("inspect")
    aboutAct = newSimpleAction("about")
    darkModeAct = newPropertyAction("dark-mode", settings, "gtk-application-prefer-dark-theme")

  with window.actionMap:
    addAction inspectorAct
    addAction aboutAct
    addAction darkModeAct

  themeMenu.insert(0, "Dark Mode", "win.dark-mode")

  with menu:
    appendSubmenu("Theme", themeMenu)
    insert(0, "About Govee for Desktop", "win.about")
    insert(1, "Inspector", "win.inspect")

  block inspector:
    proc insp(_: SimpleAction, v: Variant) = setInteractiveDebugging(true)
    inspectorAct.connect("activate", insp)

  block about:
    aboutAct.connect("activate", abt, window)

  menuBtn.setMenuModel(menu)

  with logoutBtn:
    tooltipText = "Log out (this will exit the application)"
    connect("clicked", logout)

  with headerBar:
    packEnd logoutBtn
    packEnd menuBtn
    packStart searchButton

  let
    box       = newBox(Orientation.vertical)
    scrollwnd = newScrolledWindow()
    grid      = newGrid()

  box.append searchBar
  box.append grid
  scrollwnd.child = box

  with grid:
    columnSpacing = 10
    rowSpacing    = 10
    margin        = 15

    columnHomogeneous = true

  var 
    row, column: int = 1
    deviceButtons: seq[DeviceButton]

  for id, device in acc:
    if 
      not device.controllable or 
      not device.retrievable or
      not device.supportedCommands.allIt(it in ["turn", "color", "brightness", "colorTem"]):
      # if the device is not controllable, retrievable (we can't retrieve the device's state), or 
      # it doesn't support the commands "turn," "color," "brightness," or "colorTem," don't even bother.
      continue

    if id mod 5 == 0:
      inc row
      column = 1
    else:
      inc column

    let btn = newDeviceButton(device, acc, id)
    btn.setMargin(5)
    btn.connect("clicked", deviceWindow)
    deviceButtons.add btn

    grid.attach(btn, column, row)

  searchEntry.connect("search-changed", main.search, (deviceButtons,))
  # for some reason this fails when `deviceButtons` is not in a tuple 😒
  # We connect the signal here so `deviceButtons` is not empty

  window.child = scrollwnd
  window.show()

proc respondToKey(d: Dialog; id: int; e: PasswordEntry) = 
  debug "Responded with id of ", id

  if id == ord ResponseType.ok:
    writeFile(".KEY", e.text)
    d.destroy()
  else: 
    fatal "Response other than OK (-5) given. Exiting application..."
    quit 1 

proc appActivate(app: Application) =
  let 
    appwin      = newApplicationWindow(app)
    dialog      = newDialog()
    entry       = newPasswordEntry()
    contentArea = dialog.contentArea

  entry.showPeekIcon = true

  with contentArea:
    spacing = 15
    margin  = 10

    append newLabelWithMarkup("Please enter your " & a(href="https://twitter.com/goveeofficial/status/1383962664217444353", "Govee API Key:"))
    append entry

  with dialog:
    title        = "Enter API Key"
    modal        = true # make the dialog block input
    transientFor = appwin

    connect("response", respondToKey, entry)
    connect("response", openWindow, appwin) 

  let 
    okbtn = dialog.addButton("OK", ord ResponseType.ok)
    cancelbtn = dialog.addButton("Cancel", ord ResponseType.cancel)

  okbtn.setMargin 5
  cancelbtn.setMargin 5

  dialog.show()

  if fileExists(".KEY"): # if already setup,
    if readFile(".KEY") != "": # AND api key is not blank

      debug "KEY file exists and is not blank, opening window"
      app.setAccelsForAction("win.about", "F1")
      #app.setAccelsForAction("win.dark-mode", "<Ctrl>D")
      openWindow(dialog, 0, appwin) # open window
      

      dialog.destroy()

when isMainModule:
  let app = newApplication("app.govee.desktop")
  app.connect("activate", appActivate)

  # log stuff
  info fmt"GTK Version ", GtkVersion

  # Run app and exit with the returned exit code
  quit run(app)