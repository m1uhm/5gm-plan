# 5gm-plan

Weekly 5GM trade plan, read by the `5GM_AutoPlan_EA` MT5 expert advisor.

- **`plan.txt`**: this week's scenarios. The EA fetches
  `https://raw.githubusercontent.com/m1uhm/5gm-plan/main/plan.txt` every 15 min.
- **`ea/`**: EA source and setup guide.

Anyone with push access to this repo can change what the EA trades. Keep it to yourself and keep `InpMaxRiskPct` / `InpAllowedLogin` set in MT5.

## Plan format
One `key=value` line per item, `|`-separated; times are UK time.

```
week=YYYY-MM-DD                       (Monday; plans for any other week are ignored)
news=YYYY-MM-DD HH:MM|note=...
scenario=ID|symbol=|dir=BUY/SELL|zone=lo-hi|trigger=|entry=|tf=H4|invalid=|sl=|tp1=|tp2=|risk=
         |dxy_kill_above=|dxy_kill_below=|dxy_need_above=|dxy_need_below=
         |dxy_exit_above=|dxy_exit_below=|from=|to=(required)|close_by=
```

Educational automation. Demo first. Not financial advice.
