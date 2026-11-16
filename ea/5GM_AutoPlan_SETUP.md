# 5GM AutoPlan EA v1.10 – one-time setup (MT5 for Mac)

## 1. Install the EA (once)
1. In MT5, go to **File → Open Data Folder → MQL5 → Experts**.
2. Copy `5GM_AutoPlan_EA.mq5` into that folder.
3. In the Navigator, right-click **Expert Advisors → Refresh**. Then right-click **5GM_AutoPlan_EA → Modify**, and in MetaEditor press **F7**. The result should be **0 errors**. If not, send me the error list.

## 2. Allow the EA to download the weekly plan (once)
1. Go to **Tools → Options → Expert Advisors**.
2. Tick **Allow algorithmic trading**.
3. Tick **Allow WebRequest for listed URL**, then add `https://raw.githubusercontent.com`.

## 3. Phone push alerts (optional, once)
1. On your phone, open the MT5 app and go to **Settings → Messages**. Copy your **MetaQuotes ID**.
2. On the Mac, go to **Tools → Options → Notifications**, tick **Enable Push Notifications**, and paste the ID.

## 4. Attach the EA (once)
1. Open any chart (e.g. GBPUSD H4) and drag **5GM_AutoPlan_EA** onto it.
2. On the **Common** tab, tick **Allow Algo Trading**.
3. On the **Inputs** tab, set:
   - **InpPlanURL** = `https://raw.githubusercontent.com/m1uhm/5gm-plan/main/plan.txt`
   - **InpAllowedLogin** = your MT5 demo account number. Strongly recommended: prop-firm challenge accounts run on *demo* servers, so InpDemoOnly alone would not stop the EA trading one of those.
   - **InpDemoOnly** = true (keep this while testing)
   - **InpMaxRiskPct** = 1.0 (hard cap; the plan file can never risk more than this)
   - **InpAutoTrade** = true for auto-execute, or false for alerts only
   - **InpUKOffsetHours** = 0 in winter (GMT), 1 in summer (BST)
4. Make sure the **Algo Trading** button in the toolbar is green.

The chart's top-left corner shows a dashboard with each scenario and its state (WAITING / ZONE TAPPED / EXECUTED / INVALIDATED / EXPIRED).

## Every week
- **Plan publishing:** a new `plan.txt` goes up to GitHub after each weekly outlook. The outlook should be written *after Monday's daily close*, because Monday's range and FVGs are provisional until then. The EA re-downloads the plan every 15 minutes.
- **If no new plan arrives,** the EA ignores the old one. Plans whose `week=` isn't the current week are rejected, so last week's levels can never trade. Glance at the dashboard on Tuesday to confirm the week shown is correct.
- Keep the Mac awake and MT5 running. Alternatively, run MT5 on a VPS (MetaQuotes' built-in VPS works) so it trades while your Mac is asleep.

## How a scenario trades (e.g. GU_A, w/c 16 Nov)
1. **WAIT:** price must trade into the POI zone (1.3239–1.3266).
2. **TAPPED:** the EA alerts you. It now waits for an **H4 candle to close** back below the trigger (1.3220), without any H4 close beyond the invalidation (1.3292) first.
3. **Entry:**
   - No entry on Mondays, or if the trigger candle overlaps a listed news release (±30 min).
   - The trigger candle must show **displacement**: its range must be at least 1.5× the 20-candle average. A weak drift through the level is ignored.
   - It places two sell **limit** orders at 1.3245, each half the size. The total risk is the plan's %, capped at InpMaxRiskPct.
   - **SL:** the plan's 1.3295, or further away if the swing high made after the tap is higher (that high + 3 pips). The SL is never inside the high of the week (HOTW).
   - The TP1 half targets 1.3142; the TP2 half targets 1.3015.
   - If price is already past 1.3245, it enters at market instead.
   - It skips the trade if the RR to TP1 is below 1.5 (InpMinRR).
4. **Management:**
   - When TP1 hits, the TP2 half moves to break-even.
   - Unfilled limits are cancelled in any of these cases:
     - The window ends (Thu 22:00 UK).
     - An H4 candle closes beyond the invalidation.
     - Price runs to TP1 without filling.
     - DXY flips.
     - It's Friday 20:00 UK (weekend).
   - If a listed news release is within 30 min and nothing has filled yet, the limits are pulled. The scenario then needs a fresh trigger close after the news.
   - `close_by` (Fri 16:00 UK this week): anything still open is closed, so no swing is held into the weekend.
   - `dxy_exit_above=104.37`: GU_A is closed when DXY tags its draw.
   - If DXY prints the kill close after entry, open trades are closed (InpCloseOnDXYFlip).
5. **DXY filter:**
   - GU_A is cancelled if DXY's daily close is below 102.962.
   - EU_B only arms after that happens. Once armed, a DXY daily close back above 103.331 kills it.
   - The EA uses your broker's DXY symbol if there is one; otherwise it builds a synthetic DXY from the six component pairs. Broker DXY CFDs can differ from TradingView by 0.1–0.4, and the synthetic version needs USDSEK.
   - **If DXY can't be read at all, scenarios with DXY rules do NOT trade** (fail-closed). You'll get one alert telling you so.
   - **Broker time:** a GMT+2/+3 server (New York close) makes the H4/D candles match TradingView.

## Safety
- **InpAllowedLogin** locks trading to one account number. Set it.
- **Demo-only by default.** On a real account it only alerts, unless you set `InpDemoOnly = false`.
- `InpMaxLots` caps size; `InpMaxSpreadPips` blocks entries when spreads are wide.
- One trade per scenario per week. Its state is stored in MT5 Global Variables, so it survives restarts.

- The Strategy Tester shifts time windows by the broker's GMT offset (known limitation), so backtests of the time rules are approximate.

*Educational automation of the 5GM plan. Test on demo first. Not financial advice.*
