# Monetization Audit (2026-10-08)

Scope: the single paid feature, saving a recording directly to Photos
(`Capability.saveVideoToPhotos`, product `com.moshpit.app.pro`, non-consumable).

## Verified correct
- **Flow (Release):** `recorder.stop` -> `AppModel.entitled()` -> `ProManager.allows` -> `.gated`
  outcome -> clip kept in gallery + `presentUpgrade` -> `UpgradeSheet` -> `purchase()` ->
  `isPro` flips -> `bindProManager` -> `completePendingProAction` saves to Photos.
- **Free paths never gated:** share sheet (only the built-in "Save Video" activity is excluded
  for video files while un-entitled, `ShareSheetPresenter.excludedActivityTypes`), Save to Files,
  snapshots, gallery, social export, NDI/MJPEG, recording. `Capability` has exactly one case
  (pinned by `testOnlySaveToPhotosIsGated`).
- **StoreKit 2:** `Transaction.updates` listener started in `startStoreKit()` at init;
  entitlement from `Transaction.currentEntitlements`; revoked transactions excluded;
  `finish()` on verified transactions; unverified results throw `failedVerification` and never
  entitle; `.userCancelled` is silent, `.pending` shows an info message, errors show inline;
  UserDefaults cache avoids launch flash and is reconciled at launch.
- **Apple requirements:** Restore Purchases button (`AppStore.sync`) on the sheet; price from
  `Product.displayPrice`; no redeem-code UI or copy anywhere in the UI; no dark patterns.
- **Local testing:** `MoshPit/Configuration/MoshPit.storekit` exists (non-consumable
  `com.moshpit.app.pro`, USD 4.99) and the scheme's Run action references it. Nothing needed
  recreating despite the deletion in e17f59a (it was re-added later).
- **Privacy manifest:** no tracking, no collected data, UserDefaults with CA92.1 only. A grep
  found no other required-reason API use (file timestamps, uptime, disk space). Matches docs.
- **Tests:** entitled -> Photos path (`testEntitledUserStopSavesToPhotos`); not entitled ->
  upgrade sheet and no Photos write (`testFreeUserStopTriggersUpgradeAndSkipsPhotos`);
  share exclusion policy; `debugSetPro` precedence over the DEBUG bypass is exercised by every
  gated test, since `entitled()` returns true under DEBUG unless overridden. 4 SKTestSession
  tests skip in this environment ("configuration not reachable"), as in the baseline.

## Fixed
- Product-load failure was swallowed (`try?`), leaving an "Unlock — …" button. Now
  `loadProduct()` reports success, the sheet retries on appear, and `purchase()` shows
  "Can't reach the App Store... tap Unlock to try again."
- `restore()` ignored `AppStore.sync` errors and then said "No previous purchase found",
  which is misleading offline or after a cancelled sign-in. It now reports the failure.
- Sheet copy now says sharing and Save to Files are free and the purchase only unlocks
  direct save to Photos. Button reads "Unlock" until the price loads.

## Notes (no change made)
- If the user taps Not Now, the pending save closure is kept; an Ask-to-Buy approval later
  would still save that clip if its temp file exists. Acceptable and arguably desirable.
- `ProManager` still carries the redeem-code plumbing, intentionally unreachable.

## Needs your action
(App Store Connect checks are added in Phase 3.)
- On device: Xcode Run = bypass active (Save Video present, no sheet); Archive/TestFlight =
  paywall shows after stopping a recording.
