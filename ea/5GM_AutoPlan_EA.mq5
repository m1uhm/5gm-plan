//+------------------------------------------------------------------+
//|                                             5GM_AutoPlan_EA.mq5  |
//|  Executes the weekly 5GM outlook plan on your own account.        |
//|                                                                   |
//|  - Downloads the weekly plan (plain-text lines) from a URL        |
//|    (e.g. a GitHub raw file) every few minutes, or uses the        |
//|    InpPlanText input as a fallback.                               |
//|  - For each scenario: waits for price to tap the POI zone, then   |
//|    for an H4 (configurable) candle to CLOSE back through the      |
//|    trigger level without first closing beyond the invalidation.   |
//|  - Alerts + phone push at every stage; on confirmation places     |
//|    the trade (two halves: TP1 and TP2) sized by risk %.           |
//|  - Safety: demo-only by default, no Monday entries, news          |
//|    blackouts, one trade per scenario id, max lot cap, spread cap. |
//|                                                                   |
//|  Attach to ONE chart (any symbol). It trades the symbols named    |
//|  in the plan. Enable "Algo Trading" and add the plan URL host     |
//|  to Tools > Options > Expert Advisors > Allow WebRequest.         |
//|  Educational tool. Test on demo. Not financial advice.            |
//+------------------------------------------------------------------+
#property copyright "5GM AutoPlan"
#property version   "1.10"

#include <Trade\Trade.mqh>

//--- inputs
input string InpPlanURL        = "";      // Plan URL (raw text). Empty = use InpPlanText
input string InpPlanText       = "";      // Fallback plan (lines separated by ';;')
input int    InpRefreshMinutes = 15;      // How often to re-download the plan
input bool   InpDemoOnly       = true;    // Refuse to trade on a real account
input bool   InpAutoTrade      = true;    // false = alerts only
input long   InpAllowedLogin   = 0;       // >0 = only trade on THIS account number (protects prop/other accounts)
input double InpRiskOverride   = 0.0;     // >0 overrides plan risk % per scenario
input double InpMaxRiskPct     = 1.0;     // Hard cap on risk % per scenario, whatever the plan says
input double InpMinRR          = 1.5;     // Skip if RR to TP1 is below this
input double InpSLBufferPips   = 3.0;     // SL goes at least this far beyond the swing high/low made after the tap
input bool   InpRequireDisplacement = true; // Trigger candle range must be >= InpDispMult x 20-candle average
input double InpDispMult       = 1.5;
input bool   InpAllowNoDXY     = false;   // false = if DXY cannot be read, scenarios with DXY rules do NOT trade
input bool   InpCloseOnDXYFlip = true;    // Close open trades if DXY prints its kill close after entry
input bool   InpFridayCancel   = true;    // Cancel unfilled limits Friday 20:00 UK
input double InpMaxLots        = 5.0;     // Hard cap on total lots per scenario
input double InpMaxSpreadPips  = 3.0;     // Skip entry if spread is wider
input int    InpSlippagePoints = 30;      // Max deviation for market orders
input bool   InpSplitTP        = true;    // Split into TP1 / TP2 halves
input bool   InpBEafterTP1     = true;    // Move TP2 half to break-even when TP1 hits
input bool   InpNoMondayEntries= true;    // 5GM: no new entries on Monday
input int    InpNewsBlockMins  = 30;      // No entries this many minutes before/after news
input bool   InpUseDXYFilter   = true;    // Apply DXY invalidation lines from the plan
input string InpDXYSymbol      = "";      // Broker DXY symbol (empty = auto / synthetic)
input int    InpUKOffsetHours  = 0;       // Plan times are UK time; UK = GMT + this (0 winter, 1 summer)
input bool   InpPush           = true;    // Send phone push notifications
input long   InpMagic          = 50505;   // Magic number

//--- scenario model
enum SState { S_WAIT=0, S_TAPPED=1, S_DONE=2, S_INVALID=3, S_EXPIRED=4 };

struct Scenario
  {
   string   id;
   string   symbol;
   int      dir;          // +1 buy, -1 sell
   double   zoneLo, zoneHi;
   double   trigger;
   double   entry;        // >0 = limit entry at this price after trigger (else market)
   ENUM_TIMEFRAMES tf;
   double   invalid;      // close beyond this (on tf) kills the idea
   double   sl, tp1, tp2;
   double   risk;
   double   dxyKillAbove; // DXY daily close above -> invalid (0 = unused)
   double   dxyKillBelow; // DXY daily close below -> invalid (0 = unused)
   double   dxyNeedBelow; // scenario only ARMED while DXY daily close is below this (0 = unused)
   double   dxyNeedAbove; // scenario only ARMED while DXY daily close is above this (0 = unused)
   double   dxyExitAbove; // close trade when live DXY reaches this (DXY draw hit)
   double   dxyExitBelow;
   datetime validFrom, validTo;   // GMT
   datetime closeBy;      // GMT - close anything still open (e.g. Thursday close of a swing)
   int      state;
   datetime tappedTime;
   datetime lastBar;     // last closed candle already evaluated
   datetime retryBar;    // trigger candle whose execution is being retried (spread too wide)
  };

Scenario g_sc[];
datetime g_news[];
string   g_week = "";
string   g_planText = "";
datetime g_lastFetch = 0;
datetime g_lastBarCheck = 0;
bool     g_spreadRetry = false;   // set by Execute() when it declined only because of spread
CTrade   g_trade;

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+
void Notify(string msg)
  {
   string m = "5GM: " + msg;
   Print(m);
   Alert(m);
   if(InpPush) SendNotification(m);
  }

string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

double PipSize(string sym)
  {
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (d == 3 || d == 5) ? pt * 10.0 : pt;
  }

ENUM_TIMEFRAMES TfFromString(string s)
  {
   s = Trim(s); StringToUpper(s);
   if(s == "M15") return PERIOD_M15;
   if(s == "M30") return PERIOD_M30;
   if(s == "H1")  return PERIOD_H1;
   if(s == "D1")  return PERIOD_D1;
   return PERIOD_H4;
  }

// "2026-11-17 07:00" in UK time -> GMT datetime
datetime UKToGMT(string s)
  {
   s = Trim(s);
   StringReplace(s, "-", ".");
   datetime t = StringToTime(s);
   if(t == 0) return 0;
   return t - InpUKOffsetHours * 3600;
  }

// broker-server time of a GMT time
datetime GMTToServer(datetime gmt)
  {
   long shift = (long)TimeTradeServer() - (long)TimeGMT();
   // round to nearest 15 min to remove jitter
   shift = (long)MathRound(shift / 900.0) * 900;
   return (datetime)(gmt + shift);
  }

string StateName(int st)
  {
   switch(st)
     {
      case S_WAIT:    return "WAITING for zone";
      case S_TAPPED:  return "ZONE TAPPED - waiting for close through trigger";
      case S_DONE:    return "EXECUTED / DONE";
      case S_INVALID: return "INVALIDATED";
      case S_EXPIRED: return "EXPIRED";
     }
   return "?";
  }

string GVName(string week, string id) { return "5GM_" + week + "_" + id; }

void SaveState(int i)
  {
   string gv = GVName(g_week, g_sc[i].id);
   GlobalVariableSet(gv, g_sc[i].state);
   GlobalVariableSet(gv + "_t", (double)g_sc[i].tappedTime);
   GlobalVariableSet(gv + "_b", (double)g_sc[i].lastBar);
  }

void SaveCache(string text)
  {
   int h = FileOpen("5gm_plan_cache.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) { FileWriteString(h, text); FileClose(h); }
  }

string LoadCache()
  {
   int h = FileOpen("5gm_plan_cache.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return "";
   string s = "";
   while(!FileIsEnding(h)) s += FileReadString(h) + "\n";
   FileClose(h);
   return s;
  }

bool SymOK(string s) { return SymbolSelect(s, true) && SymbolInfoDouble(s, SYMBOL_BID) > 0; }

// handles broker suffixes like EURUSD.m / EURUSDpro
string BrokerSymbol(string base)
  {
   if(SymOK(base)) return base;
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string nm = SymbolName(i, false);
      if(StringFind(nm, base) == 0 && StringLen(nm) <= StringLen(base) + 4)
         if(SymOK(nm)) return nm;
     }
   return "";
  }

//+------------------------------------------------------------------+
//| plan parsing                                                     |
//| Format, one scenario per line, key=value separated by '|':       |
//| week=2026-11-16                                                  |
//| news=2026-11-17 13:30                                            |
//| scenario=GU_A|symbol=GBPUSD|dir=SELL|zone=1.32390-1.32663|       |
//|   trigger=1.32200|tf=H4|invalid=1.32920|sl=1.32950|tp1=1.31420|  |
//|   tp2=1.30150|risk=1.0|dxy_kill_below=102.962|                   |
//|   from=2026-11-17 00:00|to=2026-11-19 22:00                      |
//+------------------------------------------------------------------+
string KV(string &parts[], string key)
  {
   for(int i = 0; i < ArraySize(parts); i++)
     {
      string p = Trim(parts[i]);
      int eq = StringFind(p, "=");
      if(eq <= 0) continue;
      string k = Trim(StringSubstr(p, 0, eq));
      StringToLower(k);
      if(k == key) return Trim(StringSubstr(p, eq + 1));
     }
   return "";
  }

bool ParsePlan(string text)
  {
   StringReplace(text, "\r", "");
   StringReplace(text, ";;", "\n");
   if(StringLen(text) > 0 && StringGetCharacter(text, 0) == 0xFEFF) text = StringSubstr(text, 1);   // strip UTF-8 BOM
   string lines[];
   int n = StringSplit(text, '\n', lines);
   if(n <= 0) return false;

   Scenario tmp[];
   datetime news[];
   string week = "";

   for(int i = 0; i < n; i++)
     {
      string ln = Trim(lines[i]);
      if(ln == "" || StringGetCharacter(ln, 0) == '#') continue;
      string parts[];
      StringSplit(ln, '|', parts);
      string w = KV(parts, "week");
      if(w != "") { week = w; continue; }
      string nw = KV(parts, "news");
      if(nw != "") { int k = ArraySize(news); ArrayResize(news, k + 1); news[k] = UKToGMT(nw); continue; }
      string id = KV(parts, "scenario");
      if(id == "") continue;

      Scenario s;
      s.id      = id;
      s.symbol  = KV(parts, "symbol");
      string d  = KV(parts, "dir"); StringToUpper(d);
      s.dir     = (d == "BUY") ? 1 : -1;
      string z  = KV(parts, "zone");
      int dash  = StringFind(z, "-");
      if(dash <= 0) { Print("5GM: bad zone in ", id); continue; }
      double a = StringToDouble(StringSubstr(z, 0, dash));
      double b = StringToDouble(StringSubstr(z, dash + 1));
      s.zoneLo  = MathMin(a, b);
      s.zoneHi  = MathMax(a, b);
      s.trigger = StringToDouble(KV(parts, "trigger"));
      s.entry   = StringToDouble(KV(parts, "entry"));
      s.tf      = TfFromString(KV(parts, "tf"));
      s.invalid = StringToDouble(KV(parts, "invalid"));
      s.sl      = StringToDouble(KV(parts, "sl"));
      s.tp1     = StringToDouble(KV(parts, "tp1"));
      s.tp2     = StringToDouble(KV(parts, "tp2"));
      s.risk    = StringToDouble(KV(parts, "risk"));
      s.dxyKillAbove = StringToDouble(KV(parts, "dxy_kill_above"));
      s.dxyKillBelow = StringToDouble(KV(parts, "dxy_kill_below"));
      s.dxyNeedBelow = StringToDouble(KV(parts, "dxy_need_below"));
      s.dxyNeedAbove = StringToDouble(KV(parts, "dxy_need_above"));
      s.validFrom = UKToGMT(KV(parts, "from"));
      s.validTo   = UKToGMT(KV(parts, "to"));
      s.closeBy   = UKToGMT(KV(parts, "close_by"));
      s.dxyExitAbove = StringToDouble(KV(parts, "dxy_exit_above"));
      s.dxyExitBelow = StringToDouble(KV(parts, "dxy_exit_below"));
      if(s.validTo <= 0) { Print("5GM: scenario ", id, " has no to= expiry - rejected"); continue; }
      s.state     = S_WAIT;
      s.tappedTime = 0;
      s.lastBar    = 0;
      s.retryBar   = 0;
      if(s.symbol == "" || s.trigger <= 0 || s.sl <= 0 || s.tp1 <= 0)
        { Print("5GM: incomplete scenario ", id); continue; }
      if(s.tp2 <= 0) s.tp2 = s.tp1;
      int k = ArraySize(tmp); ArrayResize(tmp, k + 1); tmp[k] = s;
     }

   if(ArraySize(tmp) == 0) { Print("5GM: plan has no scenarios"); return false; }
   // stale-plan guard: plan week must be this week (Monday date, UK)
   string wk = week; StringReplace(wk, "-", ".");
   datetime wd = StringToTime(wk);
   if(wd <= 0 || TimeGMT() > wd + 7 * 86400 || TimeGMT() < wd - 3 * 86400)
     {
      static string warned = "";
      if(warned != week) { warned = week; Notify("plan week '" + week + "' is not the current week - plan ignored (publish this week's plan)"); }
      ArrayResize(g_sc, 0); g_week = week; return false;
     }

   // keep progress of scenarios that already existed (same id + week)
   for(int i = 0; i < ArraySize(tmp); i++)
     {
      for(int j = 0; j < ArraySize(g_sc); j++)
         if(g_sc[j].id == tmp[i].id && week == g_week)
           { tmp[i].state = g_sc[j].state; tmp[i].tappedTime = g_sc[j].tappedTime; tmp[i].lastBar = g_sc[j].lastBar; tmp[i].retryBar = g_sc[j].retryBar; }
      // persisted state survives restarts
      string gv = GVName(week, tmp[i].id);
      if(GlobalVariableCheck(gv)) tmp[i].state = (int)GlobalVariableGet(gv);
      if(GlobalVariableCheck(gv + "_t")) tmp[i].tappedTime = (datetime)(long)GlobalVariableGet(gv + "_t");
      if(GlobalVariableCheck(gv + "_b")) tmp[i].lastBar    = (datetime)(long)GlobalVariableGet(gv + "_b");
     }

   bool changed = (week != g_week || ArraySize(tmp) != ArraySize(g_sc));
   ArrayResize(g_sc, ArraySize(tmp));
   for(int i = 0; i < ArraySize(tmp); i++) g_sc[i] = tmp[i];
   ArrayFree(g_news); ArrayCopy(g_news, news);
   if(changed)
     {
      g_week = week;
      string msg = "Plan loaded for week " + week + ": ";
      for(int i = 0; i < ArraySize(g_sc); i++)
         msg += g_sc[i].id + " " + g_sc[i].symbol + (g_sc[i].dir > 0 ? " BUY" : " SELL") + "; ";
      Notify(msg);
     }
   return true;
  }


//+------------------------------------------------------------------+
//| plan download                                                    |
//+------------------------------------------------------------------+
void FetchPlan()
  {
   g_lastFetch = TimeLocal();   // local clock keeps running at weekends (TimeCurrent freezes without ticks)
   string text = "";
   if(InpPlanURL != "")
     {
      char post[], result[];
      string headers;
      string url = InpPlanURL;
      // cache-buster so GitHub's CDN doesn't serve an old copy
      url += (StringFind(url, "?") >= 0 ? "&" : "?") + "t=" + IntegerToString((long)TimeGMT());
      ResetLastError();
      int code = WebRequest("GET", url, "User-Agent: 5GM-AutoPlan\r\n", 10000, post, result, headers);
      if(code == 200)
        {
         text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
         SaveCache(text);
        }
      else
        {
         Print("5GM: plan download failed, HTTP ", code, " err ", GetLastError(),
               " - add the host to Tools > Options > Expert Advisors > Allow WebRequest. Using cached plan.");
         text = LoadCache();
        }
     }
   if(text == "") text = InpPlanText;
   if(text == "") { Comment("5GM AutoPlan: no plan (set InpPlanURL or InpPlanText)"); return; }
   if(text == g_planText && ArraySize(g_sc) > 0) return;
   if(ParsePlan(text)) g_planText = text;
  }


//+------------------------------------------------------------------+
//| DXY (broker symbol or synthetic ICE formula)                     |
//+------------------------------------------------------------------+
string g_dxySym = "";
bool   g_dxyResolved = false;
bool   g_dxyWarned = false;


void ResolveDXY()
  {
   g_dxyResolved = true;
   string cands[] = {"DXY", "USDX", "DX", "USDIDX", "DOLLARINDEX", "USDINDEX", "DXY.cash", "USIDX"};
   if(InpDXYSymbol != "" && SymOK(InpDXYSymbol)) { g_dxySym = InpDXYSymbol; return; }
   for(int i = 0; i < ArraySize(cands); i++) if(SymOK(cands[i])) { g_dxySym = cands[i]; return; }
   g_dxySym = "";   // synthetic
  }

// D1 close of DXY at shift (1 = previous completed day, 0 = live). 0 = unavailable
double DXYPrevDailyClose() { return DXYAt(1); }
double DXYAt(int shift)
  {
   if(!g_dxyResolved) ResolveDXY();
   if(g_dxySym != "") return iClose(g_dxySym, PERIOD_D1, shift);
   string s[] = {"EURUSD", "USDJPY", "GBPUSD", "USDCAD", "USDSEK", "USDCHF"};
   double w[] = {-0.576, 0.136, -0.119, 0.091, 0.042, 0.036};
   double v = 50.14348112;
   for(int i = 0; i < 6; i++)
     {
      string sym = BrokerSymbol(s[i]);
      if(sym == "") return 0;
      double c = iClose(sym, PERIOD_D1, shift);
      if(c <= 0) return 0;
      v *= MathPow(c, w[i]);
     }
   return v;
  }


//+------------------------------------------------------------------+
//| filters                                                          |
//+------------------------------------------------------------------+
bool InNewsBlock()
  {
   datetime now = TimeGMT();
   for(int i = 0; i < ArraySize(g_news); i++)
      if(MathAbs((long)now - (long)g_news[i]) <= InpNewsBlockMins * 60) return true;
   return false;
  }

// any news inside [fromG - block, toG + block] (GMT)
bool NewsInRange(datetime fromG, datetime toG)
  {
   for(int i = 0; i < ArraySize(g_news); i++)
      if(g_news[i] >= fromG - InpNewsBlockMins * 60 && g_news[i] <= toG + InpNewsBlockMins * 60) return true;
   return false;
  }

long ServerShift()
  {
   long sh = (long)TimeTradeServer() - (long)TimeGMT();
   return (long)MathRound(sh / 900.0) * 900;
  }

int ClosePositions(string sym, string tag)
  {
   int n = 0;
   g_trade.SetExpertMagicNumber(InpMagic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) < 0) continue;
      if(g_trade.PositionClose(tk)) n++;
     }
   return n;
  }

bool IsMondayGMT()
  {
   MqlDateTime t; TimeToStruct(TimeGMT() + InpUKOffsetHours * 3600, t);
   return t.day_of_week == 1;
  }

bool HasOpenPositions(string sym, string tag)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) >= 0) return true;
     }
   return false;
  }


bool HasPendingOrders(string sym, string tag)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), tag) >= 0) return true;
     }
   return false;
  }

int DeletePending(string sym, string tag)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), tag) < 0) continue;
      if(g_trade.OrderDelete(tk)) n++;
     }
   return n;
  }
//+------------------------------------------------------------------+
//| sizing + execution                                               |
//+------------------------------------------------------------------+
double LotsForRisk(string sym, double riskPct, double entry, double sl)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double money = bal * riskPct / 100.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double dist = MathAbs(entry - sl);
   if(tv <= 0 || ts <= 0 || dist <= 0) return 0;
   double lots = money / (dist / ts * tv);
   lots = MathMin(lots, InpMaxLots);
   return lots;
  }

double NormLots(string sym, double lots)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;            // epsilon: 0.3/0.01 = 29.999.. must not floor to 29
   int vd = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   lots = NormalizeDouble(lots, vd);                         // avoid 0.29000000000000004 -> invalid volume
   if(lots < mn || lots <= 0) return 0;
   if(mx > 0) lots = MathMin(lots, mx);
   return lots;
  }


bool Place(int dir, bool limit, double vol, string sym, double price, double sl, double tp, string comment)
  {
   if(!limit)
      return (dir > 0) ? g_trade.Buy(vol, sym, 0, sl, tp, comment) : g_trade.Sell(vol, sym, 0, sl, tp, comment);
   return (dir > 0) ? g_trade.BuyLimit(vol, price, sym, sl, tp, ORDER_TIME_GTC, 0, comment)
                    : g_trade.SellLimit(vol, price, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
  }

bool Execute(int i)
  {
   g_spreadRetry = false;
   Scenario s;
   s = g_sc[i];
   string sym = BrokerSymbol(s.symbol);
   if(sym == "") { Notify(s.id + ": symbol " + s.symbol + " not found at broker"); return false; }

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double pip = PipSize(sym);
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if((ask - bid) / pip > InpMaxSpreadPips)
     { Print("5GM: ", s.id, " spread too wide (", DoubleToString((ask - bid) / pip, 1), " pips) - will retry"); g_spreadRetry = true; return false; }

   double mkt   = (s.dir > 0) ? ask : bid;
   bool   useLimit = false;
   double entry = mkt;
   if(s.entry > 0)
     {
      // limit only if price has not yet retraced to the entry; otherwise market is the better fill
      bool better = (s.dir < 0) ? (bid >= s.entry) : (ask <= s.entry);
      if(!better) { useLimit = true; entry = NormalizeDouble(s.entry, dg); }
     }
   // dynamic SL: never inside the swing extreme made since the tap (the HOTW/LOTW being traded from)
   double slRaw = s.sl;
   int k = iBarShift(sym, s.tf, s.tappedTime);
   if(k >= 1)
     {
      if(s.dir < 0) { double hh = iHigh(sym, s.tf, iHighest(sym, s.tf, MODE_HIGH, k, 1)); if(hh > 0) slRaw = MathMax(slRaw, hh + InpSLBufferPips * pip); }
      else          { double ll = iLow(sym, s.tf, iLowest(sym, s.tf, MODE_LOW, k, 1));    if(ll > 0) slRaw = MathMin(slRaw, ll - InpSLBufferPips * pip); }
     }
   double sl    = NormalizeDouble(slRaw, dg);
   double tp1   = NormalizeDouble(s.tp1, dg);
   double tp2   = NormalizeDouble(s.tp2, dg);

   // sanity: SL/TP must be on the correct sides of the current price
   if(s.dir < 0 && !(sl > entry && tp1 < entry && sl > mkt && tp1 < mkt)) { Notify(s.id + ": price " + DoubleToString(mkt, dg) + " already beyond SL/TP - skipped"); return true; }
   if(s.dir > 0 && !(sl < entry && tp1 > entry && sl < mkt && tp1 > mkt)) { Notify(s.id + ": price " + DoubleToString(mkt, dg) + " already beyond SL/TP - skipped"); return true; }

   double rr = MathAbs(tp1 - entry) / MathAbs(entry - sl);
   if(rr < InpMinRR) { Notify(s.id + ": RR to TP1 only " + DoubleToString(rr, 2) + " at " + DoubleToString(entry, dg) + " SL " + DoubleToString(sl, dg) + " - skipped (min " + DoubleToString(InpMinRR, 1) + "R)"); return true; }

   double risk = (InpRiskOverride > 0) ? InpRiskOverride : (s.risk > 0 ? s.risk : 1.0);
   risk = MathMin(risk, InpMaxRiskPct);
   double lots = LotsForRisk(sym, risk, entry, sl);
   string info = StringFormat("%s %s %s%s @%s SL %s (%.1f pips) TP1 %s TP2 %s RR1 %.2f risk %.2f%% lots %.2f",
                              s.id, sym, (s.dir > 0 ? "BUY" : "SELL"), (useLimit ? " LIMIT" : ""), DoubleToString(entry, dg), DoubleToString(sl, dg),
                              MathAbs(entry - sl) / pip, DoubleToString(tp1, dg), DoubleToString(tp2, dg), rr, risk, lots);

   if(!InpAutoTrade) { Notify("SETUP CONFIRMED (alert-only mode): " + info); return true; }

   bool isDemo = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO);
   if(InpAllowedLogin > 0 && AccountInfoInteger(ACCOUNT_LOGIN) != InpAllowedLogin)
     { Notify("SETUP CONFIRMED but account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " is not InpAllowedLogin - NOT trading. " + info); return true; }
   if(InpDemoOnly && !isDemo) { Notify("SETUP CONFIRMED but account is REAL and InpDemoOnly=true - NOT trading. " + info); return true; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { Notify("SETUP CONFIRMED but Algo Trading is disabled - NOT trading. " + info); return true; }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(sym);

   bool ok;
   bool partial = false;
   string tag = "5GM " + s.id;
   double half = NormLots(sym, lots / 2.0);
   if(InpSplitTP && half > 0 && tp2 != tp1)
     {
      bool ok1 = Place(s.dir, useLimit, half, sym, entry, sl, tp1, tag + " TP1");
      bool ok2 = Place(s.dir, useLimit, half, sym, entry, sl, tp2, tag + " TP2");
      ok = ok1 && ok2;
      partial = (ok1 != ok2);
     }
   else
     {
      double full = NormLots(sym, lots);
      if(full <= 0) { Notify(s.id + ": lot size below broker minimum - skipped. " + info); return true; }
      ok = Place(s.dir, useLimit, full, sym, entry, sl, tp1, tag);
     }

   if(ok) Notify((useLimit ? "LIMIT ORDER PLACED: " : "TRADE PLACED: ") + info);
   else   Notify((partial ? "ONLY ONE HALF PLACED - check manually. " : "") + "ORDER FAILED (" + IntegerToString(g_trade.ResultRetcode()) + " " + g_trade.ResultRetcodeDescription() + "): " + info);
   return ok || partial;   // one half live -> scenario is DONE (never re-enter)
  }

// move TP2 half to break-even once the TP1 half is gone
void ManageBE()
  {
   if(!InpBEafterTP1) return;
   for(int i = 0; i < ArraySize(g_sc); i++)
     {
      if(g_sc[i].state != S_DONE) continue;
      string sym = BrokerSymbol(g_sc[i].symbol);
      if(sym == "") continue;
      string tag = "5GM " + g_sc[i].id;
      if(HasOpenPositions(sym, tag + " TP1")) continue;       // TP1 still running
      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         ulong tk = PositionGetTicket(p);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(StringFind(PositionGetString(POSITION_COMMENT), tag + " TP2") != 0) continue;
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur  = PositionGetDouble(POSITION_SL);
         long   type = PositionGetInteger(POSITION_TYPE);
         bool better = (type == POSITION_TYPE_BUY) ? (cur < open) : (cur > open || cur == 0);
         // only if the TP1 half closed in profit: price must be beyond entry
         double px = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
         bool inProfit = (type == POSITION_TYPE_BUY) ? (px > open) : (px < open);
         if(better && inProfit)
           {
            g_trade.SetExpertMagicNumber(InpMagic);
            if(g_trade.PositionModify(tk, open, PositionGetDouble(POSITION_TP)))
               Notify(g_sc[i].id + ": TP1 hit - runner moved to break-even");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| scenario engine - runs on each new closed candle of scenario tf  |
//+------------------------------------------------------------------+
void Evaluate()
  {
   datetime nowG = TimeGMT();
   double dxyClose = 0;
   bool dxyTried = false;

   for(int i = 0; i < ArraySize(g_sc); i++)
     {
      string sym = BrokerSymbol(g_sc[i].symbol);
      if(sym == "") continue;
      if(g_sc[i].state == S_DONE)
        {
         string tg = "5GM " + g_sc[i].id;
         // DXY kill after entry -> cancel pendings, optionally close
         bool dxyFlip = false;
         if(InpUseDXYFilter && (g_sc[i].dxyKillAbove > 0 || g_sc[i].dxyKillBelow > 0))
           {
            if(!dxyTried) { dxyClose = DXYPrevDailyClose(); dxyTried = true; }
            if(dxyClose > 0)
               dxyFlip = (g_sc[i].dxyKillBelow > 0 && dxyClose < g_sc[i].dxyKillBelow) || (g_sc[i].dxyKillAbove > 0 && dxyClose > g_sc[i].dxyKillAbove);
           }
         // DXY reached its draw -> take profit on everything
         bool dxyDraw = false;
         if(g_sc[i].dxyExitAbove > 0 || g_sc[i].dxyExitBelow > 0)
           {
            double dl = DXYAt(0);
            if(dl > 0) dxyDraw = (g_sc[i].dxyExitAbove > 0 && dl >= g_sc[i].dxyExitAbove) || (g_sc[i].dxyExitBelow > 0 && dl <= g_sc[i].dxyExitBelow);
           }
         bool timeUp = (g_sc[i].closeBy > 0 && nowG >= g_sc[i].closeBy);
         if(HasOpenPositions(sym, tg) && (timeUp || dxyDraw || (dxyFlip && InpCloseOnDXYFlip)))
           {
            int c0 = ClosePositions(sym, tg);
            if(c0 > 0) Notify(g_sc[i].id + ": closed " + IntegerToString(c0) + " position(s) - " + (timeUp ? "close_by time reached" : (dxyDraw ? "DXY reached its draw" : "DXY flipped against the idea")));
           }
         if(HasPendingOrders(sym, tg))
           {
            double cc = iClose(sym, g_sc[i].tf, 1);
            bool invNow = (g_sc[i].invalid > 0 && cc > 0) && ((g_sc[i].dir < 0) ? (cc > g_sc[i].invalid) : (cc < g_sc[i].invalid));
            bool late   = (g_sc[i].validTo > 0 && nowG > g_sc[i].validTo) || timeUp;
            double px   = (g_sc[i].dir < 0) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
            bool tp1Run = (px > 0) && ((g_sc[i].dir < 0) ? (px <= g_sc[i].tp1) : (px >= g_sc[i].tp1));
            MqlDateTime uk; TimeToStruct(nowG + InpUKOffsetHours * 3600, uk);
            bool friday = InpFridayCancel && uk.day_of_week == 5 && uk.hour >= 20;
            bool news   = NewsInRange(nowG, nowG + InpNewsBlockMins * 60);
            if(invNow || late || tp1Run || friday || dxyFlip || dxyDraw)
              {
               int k = DeletePending(sym, tg);
               if(k > 0) Notify(g_sc[i].id + ": cancelled " + IntegerToString(k) + " unfilled limit(s) - " +
                                (invNow ? "invalidated" : late ? "window ended" : tp1Run ? "price ran to TP1 without filling" : friday ? "weekend" : "DXY"));
              }
            else if(news && !HasOpenPositions(sym, tg))
              {
               int k = DeletePending(sym, tg);
               if(k > 0) { g_sc[i].state = S_TAPPED; SaveState(i); Notify(g_sc[i].id + ": pulled " + IntegerToString(k) + " unfilled limit(s) ahead of news - will need a fresh trigger close after it"); }
              }
           }
         continue;
        }
      if(g_sc[i].state == S_INVALID || g_sc[i].state == S_EXPIRED) continue;

      if(g_sc[i].validTo > 0 && nowG > g_sc[i].validTo)
        { g_sc[i].state = S_EXPIRED; SaveState(i); Notify(g_sc[i].id + ": window ended without a trigger - expired"); continue; }

      // arming condition on DXY (e.g. 'only after DXY flips below X') - checked FIRST so kill levels only apply once armed
      if(InpUseDXYFilter && (g_sc[i].dxyNeedBelow > 0 || g_sc[i].dxyNeedAbove > 0))
        {
         if(!dxyTried) { dxyClose = DXYPrevDailyClose(); dxyTried = true; }
         if(dxyClose <= 0) continue;   // cannot verify -> stay unarmed
         if(g_sc[i].dxyNeedBelow > 0 && !(dxyClose < g_sc[i].dxyNeedBelow)) continue;
         if(g_sc[i].dxyNeedAbove > 0 && !(dxyClose > g_sc[i].dxyNeedAbove)) continue;
        }

      // DXY daily-close invalidation
      if(InpUseDXYFilter && (g_sc[i].dxyKillAbove > 0 || g_sc[i].dxyKillBelow > 0))
        {
         if(!dxyTried) { dxyClose = DXYPrevDailyClose(); dxyTried = true; }
         if(dxyClose <= 0 && !g_dxyWarned) { g_dxyWarned = true; Notify("DXY not available (broker DXY or EURUSD/USDJPY/GBPUSD/USDCAD/USDSEK/USDCHF needed) - " + (InpAllowNoDXY ? "DXY filter skipped" : "scenarios with DXY rules will NOT trade")); }
         if(dxyClose <= 0 && !InpAllowNoDXY) continue;
         if(dxyClose > 0)
           {
            if(g_sc[i].dxyKillBelow > 0 && dxyClose < g_sc[i].dxyKillBelow)
              { g_sc[i].state = S_INVALID; SaveState(i); Notify(g_sc[i].id + ": DXY daily close " + DoubleToString(dxyClose, 3) + " below " + DoubleToString(g_sc[i].dxyKillBelow, 3) + " - idea INVALID"); continue; }
            if(g_sc[i].dxyKillAbove > 0 && dxyClose > g_sc[i].dxyKillAbove)
              { g_sc[i].state = S_INVALID; SaveState(i); Notify(g_sc[i].id + ": DXY daily close " + DoubleToString(dxyClose, 3) + " above " + DoubleToString(g_sc[i].dxyKillAbove, 3) + " - idea INVALID"); continue; }
           }
        }

      // last CLOSED candle on the scenario timeframe
      double c  = iClose(sym, g_sc[i].tf, 1);
      double h  = iHigh(sym, g_sc[i].tf, 1);
      double l  = iLow(sym, g_sc[i].tf, 1);
      datetime bt = iTime(sym, g_sc[i].tf, 1);
      if(c <= 0) continue;
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(bt <= 0) continue;
      bool newBar = (bt != g_sc[i].lastBar);
      g_sc[i].lastBar = bt;
      if(newBar) SaveState(i);   // persist lastBar so a restart does not re-evaluate an old candle

      // candle-close invalidation (body close beyond invalid)
      if(g_sc[i].invalid > 0 && newBar)
        {
         bool inv = (g_sc[i].dir < 0) ? (c > g_sc[i].invalid) : (c < g_sc[i].invalid);
         if(inv) { g_sc[i].state = S_INVALID; SaveState(i); Notify(g_sc[i].id + ": " + EnumToString(g_sc[i].tf) + " closed " + DoubleToString(c, dg) + " beyond invalidation " + DoubleToString(g_sc[i].invalid, dg) + " - idea INVALID"); continue; }
        }

      if(g_sc[i].state == S_WAIT)
        {
         // zone tap: candle traded into the POI
         bool tap = (g_sc[i].dir < 0) ? (h >= g_sc[i].zoneLo) : (l <= g_sc[i].zoneHi);
         datetime tapBar = bt;                       // candle that contains the tap
         // also count a live tap on the forming candle
         double live = (g_sc[i].dir < 0) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
         if(!tap && live > 0)
           {
            tap = (g_sc[i].dir < 0) ? (live >= g_sc[i].zoneLo) : (live <= g_sc[i].zoneHi);
            tapBar = iTime(sym, g_sc[i].tf, 0);      // forming candle: its own close may be the trigger
            if(tapBar <= 0) tapBar = bt + PeriodSeconds(g_sc[i].tf);
           }
         if(tap && (g_sc[i].validFrom == 0 || nowG >= g_sc[i].validFrom - 86400 * 3))
           {
            g_sc[i].state = S_TAPPED; g_sc[i].tappedTime = tapBar; SaveState(i);
            Notify(g_sc[i].id + ": " + sym + " tapped the POI " + DoubleToString(g_sc[i].zoneLo, dg) + "-" + DoubleToString(g_sc[i].zoneHi, dg) +
                   " - now waiting for " + EnumToString(g_sc[i].tf) + " close " + (g_sc[i].dir < 0 ? "below " : "above ") + DoubleToString(g_sc[i].trigger, dg));
           }
         // a tap seen on the just-closed candle falls through so that SAME candle's close is checked as the trigger
         if(g_sc[i].state != S_TAPPED) continue;
        }

      if(g_sc[i].state == S_TAPPED)
        {
         bool retrying = (g_sc[i].retryBar > 0 && g_sc[i].retryBar == bt);
         if(!newBar && !retrying) continue;   // evaluate each closed candle once (except spread retries)
         g_sc[i].retryBar = 0;
         bool fired = (g_sc[i].dir < 0) ? (c < g_sc[i].trigger) : (c > g_sc[i].trigger);
         if(!fired) continue;
         // the trigger close must come after the tap
         if(bt < g_sc[i].tappedTime) continue;

         if(g_sc[i].validFrom > 0 && nowG < g_sc[i].validFrom)
           { Print("5GM: ", g_sc[i].id, " trigger before window opens - waiting"); continue; }
         if(InpNoMondayEntries && IsMondayGMT())
           { Notify(g_sc[i].id + ": trigger printed on Monday - 5GM rule, no entry; will re-check on next close"); continue; }
         datetime bOpenG = (datetime)((long)bt - ServerShift());
         if(InNewsBlock() || NewsInRange(bOpenG, bOpenG + PeriodSeconds(g_sc[i].tf)))
           { Notify(g_sc[i].id + ": trigger candle overlaps a news release - not taken, waiting for the next close"); continue; }
         if(InpRequireDisplacement)
           {
            double sum = 0; int cnt = 0;
            for(int b = 2; b <= 21; b++) { double hh = iHigh(sym, g_sc[i].tf, b), ll = iLow(sym, g_sc[i].tf, b); if(hh > 0 && ll > 0) { sum += hh - ll; cnt++; } }
            double avg = (cnt > 0) ? sum / cnt : 0;
            if(avg > 0 && (h - l) < InpDispMult * avg)
              { Notify(g_sc[i].id + ": close through trigger but no displacement (range " + DoubleToString((h - l) / PipSize(sym), 1) + " pips < " + DoubleToString(InpDispMult, 1) + "x avg) - waiting for a stronger close"); continue; }
           }
         if(HasOpenPositions(sym, "5GM " + g_sc[i].id) || HasPendingOrders(sym, "5GM " + g_sc[i].id))
           { g_sc[i].state = S_DONE; SaveState(i); continue; }

         if(!retrying)
            Notify(g_sc[i].id + ": TRIGGER - " + EnumToString(g_sc[i].tf) + " closed " + DoubleToString(c, dg) + (g_sc[i].dir < 0 ? " below " : " above ") + DoubleToString(g_sc[i].trigger, dg));
         if(Execute(i)) { g_sc[i].state = S_DONE; SaveState(i); }
         else if(g_spreadRetry) g_sc[i].retryBar = bt;   // re-try on the next 30s timer while this candle is still the last closed one
        }
     }
  }

void Dashboard()
  {
   string s = "5GM AutoPlan v1.10  |  week " + g_week + "  |  " + (InpAutoTrade ? "AUTO-TRADE" : "ALERT ONLY") +
              (InpDemoOnly ? " (demo only)" : "") + "\n";
   if(InpPlanURL != "") s += "Plan source: URL (refresh " + IntegerToString(InpRefreshMinutes) + " min)\n";
   for(int i = 0; i < ArraySize(g_sc); i++)
      s += StringFormat("%s  %s %s  zone %.5f-%.5f  trigger %.5f  SL %.5f  TP %.5f/%.5f  ->  %s\n",
                        g_sc[i].id, g_sc[i].symbol, (g_sc[i].dir > 0 ? "BUY" : "SELL"), g_sc[i].zoneLo, g_sc[i].zoneHi,
                        g_sc[i].trigger, g_sc[i].sl, g_sc[i].tp1, g_sc[i].tp2, StateName(g_sc[i].state));
   if(InNewsBlock()) s += "NEWS BLACKOUT ACTIVE\n";
   Comment(s);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   FetchPlan();
   EventSetTimer(30);
   Dashboard();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }

void OnTimer()
  {
   if(TimeLocal() - g_lastFetch >= InpRefreshMinutes * 60) FetchPlan();
   Evaluate();
   ManageBE();
   Dashboard();
  }

void OnTick() { /* logic runs on the 30s timer so it works for any symbol in the plan */ }
//+------------------------------------------------------------------+
