# App Store screenshots

`screenshots/` holds the five images for the App Store listing, at the 6.9-inch
iPhone size (1320 × 2868) — the only set an iPhone-only app needs.

They are composed, not hand-made: `raw/` has plain simulator captures,
`compose.html` adds the headline and device frame, and `render.sh` renders each
one with headless Chrome:

```sh
./AppStore/render.sh
```

Headlines and the screen order live in the `SHOTS` table in `compose.html`.

## Retaking the raw captures

1. Run the demo server locally (`docker compose -f docker-compose.demo.yml up -d`
   in the server repo) and seed it with `python3 scripts/seed_demo.py --skip-workouts`.
2. Run a Debug build on an iPhone 17 Pro Max simulator and sign in to
   `http://localhost:8011` as the demo athlete.
3. Settings → Developer: untick "mark as synced" and run the seeder. It writes
   six months of runs and thirty days of sleep, recovery, body, activity and
   nutrition samples, so every screen has data.
4. Set a clean status bar and capture:

   ```sh
   xcrun simctl status_bar booted override --time "9:41" --batteryState charged \
     --batteryLevel 100 --wifiBars 3 --cellularBars 4
   xcrun simctl io booted screenshot AppStore/raw/01-training.png
   ```

The route in `raw/03-run-top.png` was captured with a real GPS trace swapped into
the seeder locally; the seeder in the repo draws a generic riverfront line.
