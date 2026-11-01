# The animation at the top of the READMEs, recorded with VHS
# (https://github.com/charmbracelet/vhs) by .github/workflows/demo-recording.yml.
# The sandbox must already be running: docker compose up -d --wait
#   vhs docs/demo.tape

Output docs/demo.gif
Output docs/demo.mp4

Require docker

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 17
Set Width 1280
Set Height 980
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set Framerate 15
Set TypingSpeed 75ms

# Off camera: a first run warms Trino up, so the recorded one answers at once.
# Then four seconds between the seven steps of the demo, to read each one.
Hide
Type "export PS1='$ ' && ./demo.sh --check > /dev/null; echo warm''ed"
Enter
Wait+Screen@120s /warmed/
Type "export DEMO_PACE=4 && clear"
Enter
Sleep 500ms
Show

Sleep 800ms
Type "./demo.sh"
Sleep 700ms
Enter

Wait+Screen@90s /forged signature/
Sleep 7s
