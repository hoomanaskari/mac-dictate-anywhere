# Dictate Anywhere 2.8.3

- Microphone and Accessibility permission status now refreshes when returning from System Settings, so resolved warnings clear without relaunching.
- Granting microphone access for the first time no longer starts recording from the original permission gesture; press the dictation shortcut again when permission is granted.
- Permission warnings now provide clearer actions for opening the correct System Settings pages.
- Development builds now use a separate app identity and disable production update checks, preventing local testing from interfering with the installed public app.
