# The animation at the top of the READMEs, recorded with VHS
# (https://github.com/charmbracelet/vhs) by .github/workflows/demo-recording.yml.
# The sandbox must already be running: docker compose up -d --wait
#   vhs docs/demo.tape

Output docs/demo.gif
Output docs/demo.mp4

Require docker

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 16
Set Width 1280
Set Height 860
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set Framerate 24
Set TypingSpeed 75ms

# Two and a half seconds between the steps of the demo, to read each one.
Hide
Type "export DEMO_PACE=2.5 PS1='$ ' && clear"
Enter
Show

Sleep 800ms
Type "./demo.sh"
Sleep 700ms
Enter

Wait+Screen@90s /forged signature/
Sleep 8s
