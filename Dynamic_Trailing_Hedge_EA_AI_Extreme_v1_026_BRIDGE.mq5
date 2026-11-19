//+------------------------------------------------------------------+
//| Dynamic Trailing Hedge EA - AI Extreme Edition                  |
//| Version: 1.025 (v1.022 baseline + editable manual Stop step)     |
//| Broker priority: Exness MT5 | Instrument priority: XAUUSD         |
//|                                                                  |
//| IMPORTANT: This is a DEMO/TEST foundation, not a profit system.   |
//| Manages EA-owned pyramid positions and one opposite Stop order.  |
//| AI/Telegram/Email monitoring is intentionally a separate module. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.026"
#property description "Step-trailing opposite Stop, tiered pyramid and basket target"

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- Inputs ---------------------------------
input double InpLots                    = 0.01;       // Requested volume
input ulong  InpMagic                   = 18112026;   // EA magic number
input int    InpDeviationPoints         = 30;         // Max deviation (points)
input double InpInitialStopDistanceUnits = 100.0;     // 100 units = 10 pips (XAUUSD 3-digit convention)
input double InpTriggerDistancePips     = 10.0;       // Start trailing after this gain
input double InpTrailDistance1Pips      = 5.0;        // Trail distance at first tier
input double InpTier2FromPips           = 20.0;       // Switch to tier 2 at this gain
input double InpTrailDistance2Pips      = 10.0;       // Trail distance at second tier
input double InpPipSizeOverride         = 0.0;        // 0=auto; otherwise price units per pip
input double InpExtraStopBufferPoints   = 2.0;        // Extra buffer beyond broker stop/freeze
input int    InpRetryMax                = 3;          // Bounded retry count per operation
input int    InpRetryDelayMs            = 150;        // Retry delay
input bool   InpAllowBuyButton          = true;       // Show BUY button
input bool   InpAllowSellButton         = true;       // Show SELL button
input bool   InpCloseOnMissingStop      = true;       // Close position if protective stop cannot be installed
input bool   InpEnableAutoEntry         = true;       // Auto-start BUY when no EA cycle exists
input double InpAddFirstAfterPips       = 20.0;       // First add-on threshold from cycle anchor
input double InpAddEveryPips            = 10.0;       // Subsequent add-on interval
input int    InpMaxPositionsPerCycle    = 10;         // Safety cap, including initial position
input double InpHedgeStopLots           = 0.01;       // Fixed opposite Stop volume
input double InpCycleTakeProfitUSD      = 5.0;        // Net cycle target in account currency
input int    InpMaxBackfillPerPass      = 10;         // Maximum missed pyramid levels per pass
input bool   InpDebugLog                = true;
input bool   InpShowDailySummary        = true;       // Show daily entry count and lots / Hiển thị tổng kết lệnh và lot trong ngày
input bool   InpEnablePhoneBridge       = false;      // Enable phone control bridge (Demo testing first)
input string InpBridgeUrl               = "http://127.0.0.1:8765"; // Windows Bridge URL
input string InpBridgeToken             = "";         // Must match Windows Bridge token
input int    InpBridgePollSeconds       = 1;          // Network polling interval (seconds)

//--------------------------- State ----------------------------------
enum ENUM_ENGINE_STATE
{
   ENGINE_IDLE = 0,
   ENGINE_OPENING,
   ENGINE_INSTALLING_STOP,
   ENGINE_MANAGING,
   ENGINE_RECOVERY,
   ENGINE_ERROR
};

ENUM_ENGINE_STATE g_state = ENGINE_IDLE;
bool   g_busy = false;
datetime g_last_auto_attempt = 0;
datetime g_cycle_start_time = 0;
bool   g_recovery_required = false;
ulong  g_position_ticket = 0;
ulong  g_pending_ticket = 0;
double g_initial_entry = 0.0;
double g_initial_stop_distance_pips = 10.0; // Internal value is always expressed in pips
int    g_cycle_direction = -1; // POSITION_TYPE_BUY / POSITION_TYPE_SELL
double g_cycle_anchor = 0.0;
double g_best_favourable = 0.0;
int    g_last_add_level = 0;
int    g_operation_failures = 0;
string BTN_BUY   = "DTH_BUY_BUTTON";
string BTN_SELL  = "DTH_SELL_BUTTON";
string BTN_FLAT  = "DTH_CLOSE_BUTTON";
string EDIT_STOP = "DTH_INITIAL_STOP_EDIT";
string BTN_APPLY = "DTH_APPLY_STOP_DISTANCE";
string DAILY_LABEL_PREFIX = "DTH_DAILY_SUMMARY_";
string BTN_MOVE_STOP = "DTH_MOVE_STOP_STEP";
string EDIT_MOVE_STEP = "DTH_MOVE_STOP_STEP_EDIT";

//--------------------------- Logging --------------------------------
void Log(const string msg)
{
   if(InpDebugLog)
      Print("[DTH] ", msg);
}

bool IsRetcodeSuccess(const uint rc)
{
   return (rc == TRADE_RETCODE_DONE ||
           rc == TRADE_RETCODE_PLACED ||
           rc == TRADE_RETCODE_DONE_PARTIAL ||
           rc == TRADE_RETCODE_NO_CHANGES);
}

//--------------------------- Symbol adaptation ----------------------
double PipSize()
{
   if(InpPipSizeOverride > 0.0)
      return InpPipSizeOverride;

   // FX convention: 5/3 digit quotes => 1 pip = 10 points.
   // 4/2 digit quotes => 1 pip = 1 point.
   // For metals/CFDs this is a configurable convention, not universal.
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
      return point * 10.0; // default gold convention; user may override

   if(digits == 3 || digits == 5)
      return point * 10.0;

   return point;
}

double NormalizePriceToTick(const double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick_size <= 0.0)
      return NormalizeDouble(price, digits);

   double rounded = MathRound(price / tick_size) * tick_size;
   return NormalizeDouble(rounded, digits);
}

double NormalizeVolume(const double requested)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || vmin <= 0.0 || vmax <= 0.0)
      return 0.0;

   double volume = MathMax(vmin, MathMin(vmax, requested));
   volume = MathFloor((volume - vmin) / step + 1e-8) * step + vmin;

   int vol_digits = 2;
   if(step >= 1.0) vol_digits = 0;
   else if(step >= 0.1) vol_digits = 1;
   else if(step >= 0.01) vol_digits = 2;
   else if(step >= 0.001) vol_digits = 3;
   else vol_digits = 4;

   return NormalizeDouble(volume, vol_digits);
}

bool TradingEnvironmentReady(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      reason = "Terminal is not connected to trade server";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      reason = "EA trading is not allowed";
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      reason = "Terminal AutoTrading is disabled";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      reason = "Account trading is not allowed";
      return false;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      reason = "This EA requires an MT5 hedging account";
      return false;
   }
   reason = "OK";
   return true;
}

// Returns the minimum safe distance in price units.
double BrokerMinDistance()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double broker_points = (double)MathMax(stops, freeze);
   return (broker_points + InpExtraStopBufferPoints) * point;
}

int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

// If an opposite Stop is triggered, hedging mode can briefly contain
// both the old and the newly activated position. Keep the newest position
// and close older EA-owned positions before starting the next cycle.
bool ReconcileReversePositions()
{
   ulong newest_ticket = 0;
   long newest_time = -1;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long opened = (long)PositionGetInteger(POSITION_TIME_MSC);
      if(opened > newest_time)
      {
         newest_time = opened;
         newest_ticket = t;
      }
   }

   if(newest_ticket == 0)
      return true;

   bool all_closed = true;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || t == newest_ticket || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      Log("Reverse detected: closing older position #" + (string)t +
          ", keeping newest #" + (string)newest_ticket);
      bool closed = false;
      for(int attempt = 1; attempt <= InpRetryMax; ++attempt)
      {
         if(!TerminalInfoInteger(TERMINAL_CONNECTED))
            break;
         if(trade.PositionClose(t, InpDeviationPoints) &&
            IsRetcodeSuccess(trade.ResultRetcode()))
         {
            closed = true;
            break;
         }
         Log("Older-position close attempt " + (string)attempt +
             " failed: " + trade.ResultRetcodeDescription());
         Sleep(InpRetryDelayMs);
      }
      if(!closed)
         all_closed = false;
   }
   return all_closed;
}

bool FindOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type,
                     double &volume, double &open_price)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      volume = PositionGetDouble(POSITION_VOLUME);
      open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      return true;
   }
   return false;
}

bool FindOurOppositeStop(ulong &ticket, ENUM_ORDER_TYPE &type,
                         double &volume, double &price)
{
   ticket = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP)
         continue;

      ticket = t;
      type = ot;
      volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

bool DeleteOurPendingStops()
{
   bool all_ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_SELL_STOP)
      {
         if(!trade.OrderDelete(t))
         {
            all_ok = false;
            Log("Failed to delete pending order #" + (string)t +
                " retcode=" + (string)trade.ResultRetcode());
         }
      }
   }
   return all_ok;
}

bool CloseOurPosition()
{
   ulong ticket;
   ENUM_POSITION_TYPE type;
   double volume, open_price;
   if(!FindOurPosition(ticket, type, volume, open_price))
      return true;

   for(int attempt = 1; attempt <= InpRetryMax; ++attempt)
   {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;

      if(trade.PositionClose(ticket, InpDeviationPoints))
      {
         uint rc = trade.ResultRetcode();
         if(IsRetcodeSuccess(rc))
            return true;
      }

      Log("Close attempt " + (string)attempt + " failed. retcode=" +
          (string)trade.ResultRetcode() + " " + trade.ResultRetcodeDescription());
      Sleep(InpRetryDelayMs);
   }
   return false;
}

bool CalculateStopPrice(const ENUM_POSITION_TYPE pos_type,
                        const double current_bid, const double current_ask,
                        const double entry, const double best_price,
                        double &stop_price)
{
   double pip = PipSize();
   if(pip <= 0.0)
      return false;

   double gain_pips = 0.0;
   if(pos_type == POSITION_TYPE_BUY)
      gain_pips = (best_price - entry) / pip;
   else
      gain_pips = (entry - best_price) / pip;

   double min_distance = BrokerMinDistance();

   if(pos_type == POSITION_TYPE_BUY)
   {
      // Initial protective SELL STOP is configured pips below BUY entry.
      // Existing two-tier trailing takes over after favourable movement.
      if(gain_pips < InpTriggerDistancePips)
         stop_price = entry - g_initial_stop_distance_pips * pip;
      else
      {
         double trail = (gain_pips >= InpTier2FromPips ?
                         InpTrailDistance2Pips : InpTrailDistance1Pips);
         stop_price = best_price - trail * pip;
      }

      // SELL STOP must be below current Bid by broker minimum distance.
      // Broker restrictions may move it farther away, never closer.
      double highest_valid = current_bid - min_distance;
      stop_price = MathMin(stop_price, highest_valid);
   }
   else
   {
      // Initial protective BUY STOP is configured pips above SELL entry.
      // Existing two-tier trailing takes over after favourable movement.
      if(gain_pips < InpTriggerDistancePips)
         stop_price = entry + g_initial_stop_distance_pips * pip;
      else
      {
         double trail = (gain_pips >= InpTier2FromPips ?
                         InpTrailDistance2Pips : InpTrailDistance1Pips);
         stop_price = best_price + trail * pip;
      }

      // BUY STOP must be above current Ask by broker minimum distance.
      // Broker restrictions may move it farther away, never closer.
      double lowest_valid = current_ask + min_distance;
      stop_price = MathMax(stop_price, lowest_valid);
   }

   stop_price = NormalizePriceToTick(stop_price);

   // Final directional validation after tick-size rounding.
   if(pos_type == POSITION_TYPE_BUY && stop_price >= current_bid)
      return false;
   if(pos_type == POSITION_TYPE_SELL && stop_price <= current_ask)
      return false;

   return (stop_price > 0.0);
}

bool PlaceOppositeStop(const ENUM_POSITION_TYPE pos_type,
                       const double volume, const double stop_price)
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok = false;
   if(pos_type == POSITION_TYPE_BUY)
      ok = trade.SellStop(volume, stop_price, _Symbol, 0.0, 0.0,
                          ORDER_TIME_GTC, 0, "DTH opposite SELL STOP");
   else
      ok = trade.BuyStop(volume, stop_price, _Symbol, 0.0, 0.0,
                         ORDER_TIME_GTC, 0, "DTH opposite BUY STOP");

   if(!ok || !IsRetcodeSuccess(trade.ResultRetcode()))
   {
      Log("Place opposite stop failed. retcode=" +
          (string)trade.ResultRetcode() + " " + trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool ModifyOppositeStop(const ulong ticket, const double new_price)
{
   if(!OrderSelect(ticket))
      return false;

   double old_price = OrderGetDouble(ORDER_PRICE_OPEN);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Avoid noisy modifications that do not move at least one tick.
   if(MathAbs(new_price - old_price) < tick * 0.5)
      return true;

   bool ok = trade.OrderModify(ticket, new_price, 0.0, 0.0,
                               ORDER_TIME_GTC, 0);
   if(!ok || !IsRetcodeSuccess(trade.ResultRetcode()))
   {
      Log("Modify pending stop failed. retcode=" +
          (string)trade.ResultRetcode() + " " + trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

int CountOurPositionsByType(const ENUM_POSITION_TYPE wanted)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==wanted)
         count++;
   }
   return count;
}

bool GetCycleAnchor(const ENUM_POSITION_TYPE wanted, double &anchor, long &oldest_time)
{
   bool found=false; oldest_time=0; anchor=0.0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=wanted) continue;
      long tm=(long)PositionGetInteger(POSITION_TIME_MSC);
      if(!found || tm<oldest_time)
      { found=true; oldest_time=tm; anchor=PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return found;
}

bool OpenCycleMarketOrder(const ENUM_ORDER_TYPE order_type,const double requested_lots,const string comment)
{
   if(!g_phone_trading_enabled) { Log("New entry blocked: EA paused from phone."); return false; }
   string reason;
   if(!TradingEnvironmentReady(reason)) { Log("Entry blocked: "+reason); return false; }
   double volume=NormalizeVolume(requested_lots);
   if(volume<=0.0) { Log("Invalid order volume."); return false; }
   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return false;
   double px=(order_type==ORDER_TYPE_BUY ? tk.ask : tk.bid), margin=0.0;
   if(!OrderCalcMargin(order_type,_Symbol,volume,px,margin) ||
      AccountInfoDouble(ACCOUNT_MARGIN_FREE)<margin)
   { Log("Insufficient margin for add-on order."); return false; }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=(order_type==ORDER_TYPE_BUY ? trade.Buy(volume,_Symbol,0,0,0,comment)
                                       : trade.Sell(volume,_Symbol,0,0,0,comment));
   if(!ok || !IsRetcodeSuccess(trade.ResultRetcode()))
   { Log("Market order failed: "+trade.ResultRetcodeDescription()); return false; }
   return true;
}


double PyramidLotsForIndex(const int n)
{
   if(n<=2) return 0.01;
   if(n<=4) return 0.02;
   if(n<=6) return 0.03;
   if(n<=8) return 0.04;
   return 0.05;
}

int CountOurPendingStops()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;--i)
   {
      ulong t=OrderGetTicket(i);
      if(t==0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_SELL_STOP) n++;
   }
   return n;
}

bool CloseAllOurPositions()
{
   bool ok=true;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(!trade.PositionClose(t,InpDeviationPoints) ||
         !IsRetcodeSuccess(trade.ResultRetcode())) ok=false;
   }
   return ok && CountOurPositions()==0;
}

void ResetCycleState()
{
   g_position_ticket=0; g_pending_ticket=0;
   g_initial_entry=0; g_best_favourable=0;
   g_cycle_anchor=0; g_cycle_direction=-1; g_last_add_level=0;
   g_cycle_start_time=0;
}

// Realized deal P/L (profit, commission, swap) plus current floating P/L.
double CurrentCycleNetProfit()
{
   double net=0.0;
   datetime from=(g_cycle_start_time>0 ? g_cycle_start_time : TimeCurrent()-86400*365);
   if(HistorySelect(from,TimeCurrent()+60))
   {
      for(int i=0;i<HistoryDealsTotal();++i)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0) continue;
         if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
            (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic) continue;
         net+=HistoryDealGetDouble(d,DEAL_PROFIT);
         net+=HistoryDealGetDouble(d,DEAL_SWAP);
         net+=HistoryDealGetDouble(d,DEAL_COMMISSION);
      }
   }
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      net+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return net;
}

// Initial stop is calculated from the first entry and is never trailed.
// If broker distance rules reject it, do not move it to chase the market.
bool FixedStopPrice(const ENUM_POSITION_TYPE side,const double anchor,double &price)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) return false;
   double dist=g_initial_stop_distance_pips*PipSize();
   double p=(side==POSITION_TYPE_BUY ? anchor-dist : anchor+dist);
   p=NormalizePriceToTick(p);
   double min_dist=BrokerMinDistance();
   if(side==POSITION_TYPE_BUY && p>=tk.bid-min_dist) return false;
   if(side==POSITION_TYPE_SELL && p<=tk.ask+min_dist) return false;
   price=p;
   return p>0;
}

// Return the actual open price of the Nth position in the active cycle,
// ordered oldest-to-newest. Ticket is used as a deterministic tie-breaker.
bool GetPyramidEntryPrice(const ENUM_POSITION_TYPE side, const int rank,
                          double &entry_price)
{
   if(rank < 1) return false;
   long times[];
   ulong tickets[];
   double prices[];
   ArrayResize(times,0); ArrayResize(tickets,0); ArrayResize(prices,0);

   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side) continue;
      int n=ArraySize(tickets);
      ArrayResize(times,n+1); ArrayResize(tickets,n+1); ArrayResize(prices,n+1);
      times[n]=(long)PositionGetInteger(POSITION_TIME_MSC);
      tickets[n]=t;
      prices[n]=PositionGetDouble(POSITION_PRICE_OPEN);
   }
   int n=ArraySize(tickets);
   if(rank>n) return false;

   // Small insertion sort by open time, then ticket.
   for(int a=1;a<n;++a)
   {
      long tm=times[a]; ulong tk=tickets[a]; double px=prices[a];
      int b=a-1;
      while(b>=0 && (times[b]>tm || (times[b]==tm && tickets[b]>tk)))
      {
         times[b+1]=times[b]; tickets[b+1]=tickets[b]; prices[b+1]=prices[b];
         --b;
      }
      times[b+1]=tm; tickets[b+1]=tk; prices[b+1]=px;
   }
   entry_price=prices[rank-1];
   return entry_price>0.0;
}

// Move only in the protective direction. If a stepped price is too close
// to market for broker stop/freeze rules, retain the last valid Stop price.
void TrailOppositeStopByPyramid(const ENUM_POSITION_TYPE side,
                                const int position_count,
                                const ulong stop_ticket,
                                const double current_stop_price)
{
   if(position_count<4 || stop_ticket==0) return;

   double target=0.0;
   if(!GetPyramidEntryPrice(side,position_count-1,target))
   {
      Log("Cannot identify the previous pyramid entry; keeping current Stop.");
      return;
   }
   target=NormalizePriceToTick(target);

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) return;
   double min_distance=BrokerMinDistance();
   bool valid=(side==POSITION_TYPE_BUY ? target<tk.bid-min_distance
                                       : target>tk.ask+min_distance);
   if(!valid)
   {
      Log("Step-trailing target is inside broker stop/freeze distance; keeping last valid Stop.");
      return;
   }

   // BUY cycle: SELL STOP can only rise. SELL cycle: BUY STOP can only fall.
   bool improves=(side==POSITION_TYPE_BUY ? target>current_stop_price
                                          : target<current_stop_price);
   if(!improves) return;

   if(ModifyOppositeStop(stop_ticket,target))
      Log("Pyramid step " +(string)position_count+": opposite Stop moved to previous entry " +
          DoubleToString(target,_Digits));
}

void ManagePosition()
{
   int buys=CountOurPositionsByType(POSITION_TYPE_BUY);
   int sells=CountOurPositionsByType(POSITION_TYPE_SELL);
   int total=buys+sells;

   // A hedge activation creates the new opposite-side position.
   // Keep the newest position and close all positions on the former side.
   if(buys>0 && sells>0)
   {
      long newestBuy=-1,newestSell=-1;
      for(int i=PositionsTotal()-1;i>=0;--i)
      {
         ulong t=PositionGetTicket(i);
         if(t==0 || !PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         long tm=(long)PositionGetInteger(POSITION_TIME_MSC);
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
            newestBuy=MathMax(newestBuy,tm);
         else newestSell=MathMax(newestSell,tm);
      }
      ENUM_POSITION_TYPE newSide=(newestBuy>=newestSell ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      bool clean=true;
      for(int i=PositionsTotal()-1;i>=0;--i)
      {
         ulong t=PositionGetTicket(i);
         if(t==0 || !PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==newSide) continue;
         if(!trade.PositionClose(t,InpDeviationPoints) ||
            !IsRetcodeSuccess(trade.ResultRetcode())) clean=false;
      }
      if(!clean) { g_state=ENGINE_RECOVERY; Log("Reverse cleanup failed; entries paused."); return; }
      DeleteOurPendingStops();
      g_cycle_start_time=TimeCurrent();
      GlobalVariableSet("DTH_"+(string)InpMagic+"_"+_Symbol+"_START",(double)g_cycle_start_time);
      g_cycle_direction=(int)newSide; g_cycle_anchor=0; g_last_add_level=0;
      Log("Reverse cycle retained the newly activated 0.01 hedge position.");
      return;
   }

   if(total==0)
   {
      if(CountOurPendingStops()>0 && !DeleteOurPendingStops())
      { g_state=ENGINE_ERROR; return; }
      ResetCycleState();
      if(InpEnableAutoEntry && !g_busy &&
         (g_last_auto_attempt==0 || TimeCurrent()-g_last_auto_attempt>=3))
      {
         g_last_auto_attempt=TimeCurrent();
         g_busy=true;
         bool opened=OpenCycleMarketOrder(ORDER_TYPE_BUY,InpLots,"DTH AUTO START BUY");
         g_busy=false;
         if(opened)
         {
            g_cycle_start_time=TimeCurrent();
            GlobalVariableSet("DTH_"+(string)InpMagic+"_"+_Symbol+"_START",(double)g_cycle_start_time);
            Log("Automatic BUY cycle started.");
         }
      }
      return;
   }

   ulong posTicket=0,orderTicket=0;
   ENUM_POSITION_TYPE side=POSITION_TYPE_BUY;
   ENUM_ORDER_TYPE orderType=ORDER_TYPE_SELL_STOP;
   double posVol=0,entry=0,orderVol=0,orderPrice=0;
   if(!FindOurPosition(posTicket,side,posVol,entry)) return;

   if(g_cycle_start_time<=0)
   {
      string key="DTH_"+(string)InpMagic+"_"+_Symbol+"_START";
      if(GlobalVariableCheck(key)) g_cycle_start_time=(datetime)GlobalVariableGet(key);
      else
      {
         long oldTime=0; double oldAnchor=entry;
         GetCycleAnchor(side,oldAnchor,oldTime);
         g_cycle_start_time=(oldTime>0 ? (datetime)(oldTime/1000) : TimeCurrent());
         GlobalVariableSet(key,(double)g_cycle_start_time);
      }
   }

   long oldest=0;
   double anchor=entry;
   if(!GetCycleAnchor(side,anchor,oldest)) return;
   if(g_cycle_direction!=(int)side || g_cycle_anchor<=0)
   {
      g_cycle_direction=(int)side; g_cycle_anchor=anchor;
      g_best_favourable=anchor;
   }
   else g_cycle_anchor=anchor;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   if(side==POSITION_TYPE_BUY) g_best_favourable=MathMax(g_best_favourable,tick.bid);
   else g_best_favourable=(g_best_favourable<=0 ? tick.ask : MathMin(g_best_favourable,tick.ask));

   double net=CurrentCycleNetProfit();
   if(InpCycleTakeProfitUSD>0 && net>=InpCycleTakeProfitUSD)
   {
      Log("Cycle net profit target reached: "+DoubleToString(net,2));
      bool deleted=DeleteOurPendingStops();
      bool closed=CloseAllOurPositions();
      if(deleted && closed && CountOurPendingStops()==0)
      {
         ResetCycleState();
         GlobalVariableDel("DTH_"+(string)InpMagic+"_"+_Symbol+"_START");
         g_state=ENGINE_IDLE;
         Log("Basket closed and verified; next pass starts a new BUY cycle.");
      }
      else { g_state=ENGINE_ERROR; Log("Basket close incomplete; restart blocked."); }
      return;
   }

   double favourable=(side==POSITION_TYPE_BUY ?
      (g_best_favourable-g_cycle_anchor)/PipSize() :
      (g_cycle_anchor-g_best_favourable)/PipSize());

   // Backfill crossed levels, using the agreed 1-10 tier schedule.
   int count=CountOurPositionsByType(side);
   int cap=MathMin(InpMaxPositionsPerCycle,10);
   int maxLevel=(int)MathFloor((favourable-InpAddFirstAfterPips)/InpAddEveryPips+1e-7)+1;
   int openedThisPass=0;
   while(InpEnableAutoEntry && count<cap && openedThisPass<InpMaxBackfillPerPass &&
         maxLevel>=count && count>=1)
   {
      int nextIndex=count+1;
      double threshold=InpAddFirstAfterPips+(nextIndex-2)*InpAddEveryPips;
      if(favourable+1e-6<threshold) break;
      ENUM_ORDER_TYPE addType=(side==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(!OpenCycleMarketOrder(addType,PyramidLotsForIndex(nextIndex),
                               "DTH PYRAMID L"+(string)nextIndex)) break;
      count++; openedThisPass++;
   }

   // Keep exactly one opposite pending Stop at 0.01. From pyramid #4 onward,
   // trail it in discrete steps to the entry price of the immediately previous
   // pyramid position (BUY: move SELL STOP up; SELL: move BUY STOP down).
   bool hasStop=FindOurOppositeStop(orderTicket,orderType,orderVol,orderPrice);
   ENUM_ORDER_TYPE required=(side==POSITION_TYPE_BUY ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   double fixedLots=NormalizeVolume(0.01);
   bool valid=hasStop && orderType==required &&
      MathAbs(orderVol-fixedLots)<=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.5,1e-8);
   if(hasStop && !valid)
   {
      if(!DeleteOurPendingStops()) { g_state=ENGINE_RECOVERY; return; }
      hasStop=false;
   }
   if(hasStop && CountOurPendingStops()>1)
   {
      // Preserve one valid stop; remove any duplicate stop orders.
      bool kept=false;
      for(int i=OrdersTotal()-1;i>=0;--i)
      {
         ulong t=OrderGetTicket(i);
         if(t==0 || !OrderSelect(t)) continue;
         if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
            (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
         ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(ot!=ORDER_TYPE_BUY_STOP && ot!=ORDER_TYPE_SELL_STOP) continue;
         if(!kept && ot==required) { kept=true; continue; }
         trade.OrderDelete(t);
      }
   }
   if(!hasStop)
   {
      double fixedPrice=0;
      if(!FixedStopPrice(side,g_cycle_anchor,fixedPrice))
      {
         Log("Fixed Stop price is invalid under broker distance rules; no price chasing.");
         g_state=ENGINE_RECOVERY;
         if(InpCloseOnMissingStop)
         {
            DeleteOurPendingStops();
            if(CloseAllOurPositions()) { ResetCycleState(); g_state=ENGINE_IDLE; }
            else g_state=ENGINE_ERROR;
         }
         return;
      }
      if(!PlaceOppositeStop(side,fixedLots,fixedPrice))
      {
         g_state=ENGINE_RECOVERY;
         if(InpCloseOnMissingStop)
         {
            DeleteOurPendingStops();
            if(CloseAllOurPositions()) { ResetCycleState(); g_state=ENGINE_IDLE; }
            else g_state=ENGINE_ERROR;
         }
         return;
      }
      Log("Initial opposite Stop placed at "+DoubleToString(fixedPrice,_Digits)+".");
   }
   else
   {
      // The step is triggered only after the new pyramid position exists.
      TrailOppositeStopByPyramid(side,count,orderTicket,orderPrice);
   }
   g_state=ENGINE_MANAGING;
}

bool OpenInitialPosition(const ENUM_ORDER_TYPE order_type)
{
   if(!g_phone_trading_enabled) { Log("Manual entry blocked: EA paused from phone."); return false; }
   string reason;
   if(!TradingEnvironmentReady(reason))
   {
      Log("Cannot open: " + reason);
      return false;
   }

   if(g_busy) return false;
   g_busy = true;

   ulong existing;
   ENUM_POSITION_TYPE ptype;
   ENUM_ORDER_TYPE existing_order_type;
   double pvol, popen;
   if(FindOurPosition(existing, ptype, pvol, popen))
   {
      Log("An EA position already exists on this symbol.");
      g_busy = false;
      return false;
   }

   if(FindOurOppositeStop(existing, existing_order_type, pvol, popen))
   {
      Log("An EA pending stop already exists; refusing a duplicate entry.");
      g_busy = false;
      return false;
   }

   double volume = NormalizeVolume(InpLots);
   if(volume <= 0.0)
   {
      Log("Invalid volume after broker normalization.");
      g_busy = false;
      return false;
   }

   MqlTick entry_tick;
   if(!SymbolInfoTick(_Symbol, entry_tick))
   {
      Log("Cannot read current Bid/Ask before entry.");
      g_busy = false;
      return false;
   }
   double entry_price = (order_type == ORDER_TYPE_BUY ? entry_tick.ask : entry_tick.bid);
   double required_margin = 0.0;
   if(!OrderCalcMargin(order_type, _Symbol, volume, entry_price, required_margin))
   {
      Log("OrderCalcMargin failed; refusing entry.");
      g_busy = false;
      return false;
   }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < required_margin)
   {
      Log("Insufficient free margin; required=" +
          DoubleToString(required_margin, 2) + " free=" +
          DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
      g_busy = false;
      return false;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok = false;
   if(order_type == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, _Symbol, 0.0, 0.0, 0.0, "DTH initial BUY");
   else if(order_type == ORDER_TYPE_SELL)
      ok = trade.Sell(volume, _Symbol, 0.0, 0.0, 0.0, "DTH initial SELL");

   bool success = ok && IsRetcodeSuccess(trade.ResultRetcode());
   if(!success)
      Log("Initial entry failed: " + trade.ResultRetcodeDescription());

   g_busy = false;
   return success;
}

void CloseAllAndReset()
{
   if(g_busy) return;
   g_busy=true;
   bool deleted=DeleteOurPendingStops();
   bool closed=CloseAllOurPositions();
   if(deleted && closed && CountOurPendingStops()==0)
   {
      ResetCycleState();
      GlobalVariableDel("DTH_"+(string)InpMagic+"_"+_Symbol+"_START");
      g_state=ENGINE_IDLE;
      Log("All EA positions and pending Stops closed and verified.");
   }
   else { g_state=ENGINE_ERROR; Log("Close/reset incomplete; automatic restart blocked."); }
   g_busy=false;
}

bool MoveOppositeStopOneStep(const double step_pips)
{
   int buys = CountOurPositionsByType(POSITION_TYPE_BUY);
   int sells = CountOurPositionsByType(POSITION_TYPE_SELL);

   if((buys > 0 && sells > 0) || (buys == 0 && sells == 0))
   {
      Log("Manual Stop move unavailable: no single active EA direction.");
      return false;
   }

   ENUM_POSITION_TYPE side = (buys > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);

   ulong stop_ticket = 0;
   ENUM_ORDER_TYPE stop_type;
   double stop_volume = 0.0, stop_price = 0.0;
   if(!FindOurOppositeStop(stop_ticket, stop_type, stop_volume, stop_price))
   {
      Log("Manual Stop move unavailable: EA opposite pending Stop not found.");
      return false;
   }

   ENUM_ORDER_TYPE required_type =
      (side == POSITION_TYPE_BUY ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   if(stop_type != required_type)
   {
      Log("Manual Stop move blocked: pending Stop direction does not match active position.");
      return false;
   }

   double pip = PipSize();
   if(pip <= 0.0)
   {
      Log("Manual Stop move failed: invalid PipSize().");
      return false;
   }

   // One click moves by the user-entered number of pips.
   // This editor is in actual pips (e.g. 10 = 10 pips), unlike the
   // separate initial-stop editor which retains its v1.018 unit convention.
   if(step_pips <= 0.0 || !MathIsValidNumber(step_pips))
   {
      Log("Manual Stop move rejected: step must be a positive number of pips.");
      return false;
   }
   double step = step_pips * pip;
   double target = (side == POSITION_TYPE_BUY ? stop_price + step
                                               : stop_price - step);
   target = NormalizePriceToTick(target);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Log("Manual Stop move failed: cannot read current market price.");
      return false;
   }

   double min_distance = BrokerMinDistance();
   bool valid = (side == POSITION_TYPE_BUY ? target < tick.bid - min_distance
                                           : target > tick.ask + min_distance);
   if(!valid)
   {
      Log("Manual Stop move blocked: target is too close to market or violates broker Stop/Freeze level. Existing Stop unchanged.");
      return false;
   }

   // Defensive monotonicity: never move the protective Stop backwards.
   bool improves = (side == POSITION_TYPE_BUY ? target > stop_price
                                               : target < stop_price);
   if(!improves)
      return false;

   if(!ModifyOppositeStop(stop_ticket, target))
      return false;

   Log("Manual Stop step applied: " +
       string(side == POSITION_TYPE_BUY ? "SELL STOP moved UP" : "BUY STOP moved DOWN") +
       " by " + DoubleToString(step_pips, 2) +
       " pips. New price=" + DoubleToString(target, _Digits));
   return true;
}

//--------------------------- Chart controls -------------------------
void CreateButton(const string name, const string caption,
                  const int x, const int y, const color bg)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 100);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 26);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetString(0, name, OBJPROP_TEXT, caption);
}

void CreateStopDistanceEditor()
{
   // Live chart editor: user can change the initial opposite Stop distance
   // without removing/re-attaching the EA.
   ObjectDelete(0, EDIT_STOP);
   ObjectCreate(0, EDIT_STOP, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_YDISTANCE, 54);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_XSIZE, 105);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(0, EDIT_STOP, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetString(0, EDIT_STOP, OBJPROP_TEXT,
                   DoubleToString(g_initial_stop_distance_pips * 10.0, 1));

   CreateButton(BTN_APPLY, "APPLY (100=10 PIPS)", 125, 53, clrSteelBlue);
   ObjectSetInteger(0, BTN_APPLY, OBJPROP_XSIZE, 155);
   ObjectSetInteger(0, BTN_APPLY, OBJPROP_YSIZE, 24);
}

void CreateMoveStopStepEditor()
{
   // Editable manual Stop step, expressed directly in pips.
   ObjectDelete(0, EDIT_MOVE_STEP);
   ObjectCreate(0, EDIT_MOVE_STEP, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_XDISTANCE, 340);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_YDISTANCE, 53);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_XSIZE, 105);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(0, EDIT_MOVE_STEP, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetString(0, EDIT_MOVE_STEP, OBJPROP_TEXT, "10");

   CreateButton(BTN_MOVE_STOP, "DỜI STOP / MOVE", 450, 53, clrDarkViolet);
   ObjectSetInteger(0, BTN_MOVE_STOP, OBJPROP_XSIZE, 135);
   ObjectSetInteger(0, BTN_MOVE_STOP, OBJPROP_YSIZE, 24);
}

bool GetMoveStopStepPips(double &step_pips)
{
   if(ObjectFind(0, EDIT_MOVE_STEP) < 0)
      return false;

   string raw = ObjectGetString(0, EDIT_MOVE_STEP, OBJPROP_TEXT);
   StringTrimLeft(raw);
   StringTrimRight(raw);
   step_pips = StringToDouble(raw);

   if(step_pips <= 0.0 || !MathIsValidNumber(step_pips))
   {
      Log("Invalid manual Stop step. Enter a number greater than zero in pips.");
      return false;
   }
   return true;
}

void CreateControls()
{
   if(InpAllowBuyButton)  CreateButton(BTN_BUY, "BUY", 10, 20, clrForestGreen);
   if(InpAllowSellButton) CreateButton(BTN_SELL, "SELL", 120, 20, clrFireBrick);
   CreateButton(BTN_FLAT, "CLOSE EA", 230, 20, clrDarkOrange);
   CreateStopDistanceEditor();
   CreateMoveStopStepEditor();
}

void DeleteControls()
{
   ObjectDelete(0, BTN_BUY);
   ObjectDelete(0, BTN_SELL);
   ObjectDelete(0, BTN_FLAT);
   ObjectDelete(0, EDIT_STOP);
   ObjectDelete(0, BTN_APPLY);
   ObjectDelete(0, BTN_MOVE_STOP);
   ObjectDelete(0, EDIT_MOVE_STEP);
   DeleteDailySummary();
}

bool ApplyInitialStopDistanceFromChart()
{
   if(ObjectFind(0, EDIT_STOP) < 0)
      return false;

   string raw = ObjectGetString(0, EDIT_STOP, OBJPROP_TEXT);
   StringReplace(raw, ",", ".");
   double requested = StringToDouble(raw);

   if(requested <= 0.0 || requested > 100000.0)
   {
      Log("Invalid initial Stop distance. Enter a value greater than 0 and <= 100000 units (100 units = 10 pips).");
      ObjectSetString(0, EDIT_STOP, OBJPROP_TEXT,
                      DoubleToString(g_initial_stop_distance_pips * 10.0, 1));
      return false;
   }

   // User-facing scale: 100 entered units represent 10 pips.
   // Internal calculations continue to use actual pips.
   g_initial_stop_distance_pips = requested / 10.0;
   ObjectSetString(0, EDIT_STOP, OBJPROP_TEXT,
                   DoubleToString(requested, 1));
   Log("Initial opposite Stop distance set to " +
       DoubleToString(requested, 1) + " units = " +
       DoubleToString(g_initial_stop_distance_pips, 1) + " pips.");

   // The new distance applies only when the next cycle Stop is first placed.
   // Existing pending Stop prices are never modified.
   return true;
}


//--------------------------- Phone Bridge / TONY TRAN EA CONTROL -----
ulong g_bridge_last_poll_ms=0;
string g_bridge_last_command_id="";
bool g_bridge_poll_commands_next=true;
// Phone pause switch: blocks NEW market entries while protective management remains active.
bool g_phone_trading_enabled=true;
string PhoneTradingStateKey() { return "TONY_PHONE_EA_"+(string)InpMagic+"_"+_Symbol; }

string BridgeTrim(const string value)
{
   string x=value; StringTrimLeft(x); StringTrimRight(x); return x;
}

string JsonStringValue(const string json,const string key)
{
   string needle="\""+key+"\"";
   int p=StringFind(json,needle); if(p<0) return "";
   p=StringFind(json,":",p+StringLen(needle)); if(p<0) return "";
   p++;
   while(p<StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)==9)) p++;
   if(p>=StringLen(json) || StringGetCharacter(json,p)!='"') return "";
   int q=StringFind(json,"\"",p+1); if(q<0) return "";
   return StringSubstr(json,p+1,q-p-1);
}

double JsonNumberValue(const string json,const string key,const double fallback)
{
   string needle="\""+key+"\""; int p=StringFind(json,needle);
   if(p<0) return fallback; p=StringFind(json,":",p+StringLen(needle)); if(p<0) return fallback;
   p++; while(p<StringLen(json) && StringGetCharacter(json,p)==' ') p++;
   int q=p; while(q<StringLen(json))
   { ushort c=StringGetCharacter(json,q); if((c>='0'&&c<='9')||c=='-'||c=='.') q++; else break; }
   if(q<=p) return fallback; return StringToDouble(StringSubstr(json,p,q-p));
}

bool BridgeRequest(const string method,const string path,const string body,string &response)
{
   if(!InpEnablePhoneBridge || StringLen(InpBridgeToken)<32) return false;
   string url=BridgeTrim(InpBridgeUrl)+path;
   string headers="Authorization: Bearer "+InpBridgeToken+"\r\nContent-Type: application/json\r\n";
   char data[],result[]; string result_headers;
   if(StringLen(body)>0)
   {
      int copied=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
      if(copied>0) ArrayResize(data,copied-1); // exclude C-string terminator from HTTP body
   }
   else ArrayResize(data,0);
   ResetLastError();
   int code=WebRequest(method,url,headers,500,data,result,result_headers);
   if(code<200 || code>=300)
   {
      if(code==-1) Log("Bridge WebRequest failed. Add "+BridgeTrim(InpBridgeUrl)+" to MT5 WebRequest allow-list. Error="+(string)GetLastError());
      else Log("Bridge HTTP status="+(string)code);
      return false;
   }
   response=CharArrayToString(result,0,-1,CP_UTF8); return true;
}

void BridgeAck(const string command_id,const string status,const string message)
{
   string safe=message; StringReplace(safe,"\\","\\\\"); StringReplace(safe,"\"","\\\"");
   string body="{\"status\":\""+status+"\",\"message\":\""+safe+"\"}";
   string response; BridgeRequest("POST","/api/commands/ack/"+command_id,body,response);
}

void BridgeProcessCommand(const string json)
{
   string cid=JsonStringValue(json,"id");
   string type=JsonStringValue(json,"type");
   if(type=="") type=JsonStringValue(json,"command");
   if(cid=="" || cid==g_bridge_last_command_id) return;
   bool ok=false; string msg="Unsupported command";
   if(type=="EA_ENABLE") { g_phone_trading_enabled=true; GlobalVariableSet(PhoneTradingStateKey(),1.0); ok=true; msg="EA resumed: new entries enabled"; }
   else if(type=="EA_DISABLE") { g_phone_trading_enabled=false; GlobalVariableSet(PhoneTradingStateKey(),0.0); ok=true; msg="EA paused: new entries blocked; position protection remains active"; }
   else if(type=="BUY") { ok=OpenInitialPosition(ORDER_TYPE_BUY); msg=(ok?"BUY accepted":"BUY rejected by EA safeguards"); }
   else if(type=="SELL") { ok=OpenInitialPosition(ORDER_TYPE_SELL); msg=(ok?"SELL accepted":"SELL rejected by EA safeguards"); }
   else if(type=="CLOSE_ALL") { CloseAllAndReset(); ok=(CountOurPositions()==0 && CountOurPendingStops()==0); msg=(ok?"Close all verified":"Close all incomplete"); }
   else if(type=="MOVE_STOP")
   {
      double step=JsonNumberValue(json,"step_pips",0.0);
      if(step>0 && !g_busy) { g_busy=true; ok=MoveOppositeStopOneStep(step); g_busy=false; }
      msg=(ok?"Stop moved":"Stop move rejected; see MT5 Experts log");
   }
   else if(type=="PING") { ok=true; msg="EA online"; }
   g_bridge_last_command_id=cid;
   BridgeAck(cid,(ok?"ACK":"REJECT"),msg);
   Log("Phone command "+cid+" / "+type+" => "+(ok?"ACK":"REJECT"));
}

void BridgePoll()
{
   if(!InpEnablePhoneBridge || StringLen(InpBridgeToken)<32) return;
   ulong now=GetTickCount64();
   if(now-g_bridge_last_poll_ms<(ulong)MathMax(1,InpBridgePollSeconds)*1000) return;
   g_bridge_last_poll_ms=now;
   string response;
   // Alternate requests: one short synchronous WebRequest per interval.
   // Position management runs before this network call in OnTimer.
   if(g_bridge_poll_commands_next)
   {
      if(BridgeRequest("GET","/api/commands/next","",response))
      {
         if(StringFind(response,"\"id\"")>=0) BridgeProcessCommand(response);
      }
   }
   else
   {
      string heartbeat="{\"symbol\":\""+_Symbol+"\",\"balance\":"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+
         ",\"equity\":"+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+
         ",\"open_positions\":"+(string)CountOurPositions()+
         ",\"floating_profit\":"+DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT),2)+
         ",\"trading_enabled\":"+(g_phone_trading_enabled?"true":"false")+"}";
      BridgeRequest("POST","/api/ea/heartbeat",heartbeat,response);
   }
   g_bridge_poll_commands_next=!g_bridge_poll_commands_next;
}

//--------------------------- Daily trade summary / Tổng kết trong ngày
// Statistics use broker server time and only this chart symbol + EA magic.
datetime DailyServerStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
}

void SetDailyLabel(const int row, const string text)
{
   string name=DAILY_LABEL_PREFIX+(string)row;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,84+row*19);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void UpdateDailySummary()
{
   if(!InpShowDailySummary)
   {
      for(int r=0;r<4;r++) ObjectDelete(0,DAILY_LABEL_PREFIX+(string)r);
      return;
   }

   datetime from=DailyServerStart();
   datetime to=TimeCurrent();
   int order_count=0;
   double lots=0.0;
   ulong seen_orders[];

   if(HistorySelect(from,to))
   {
      int total=HistoryDealsTotal();
      for(int i=0;i<total;i++)
      {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0) continue;
         if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
         if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;
         if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;

         lots+=HistoryDealGetDouble(deal,DEAL_VOLUME);
         ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
         if(order==0) order=deal;
         bool found=false;
         for(int j=0;j<ArraySize(seen_orders);j++)
         {
            if(seen_orders[j]==order) { found=true; break; }
         }
         if(!found)
         {
            int n=ArraySize(seen_orders);
            ArrayResize(seen_orders,n+1);
            seen_orders[n]=order;
            order_count++;
         }
      }
   }

   SetDailyLabel(0,"TỔNG KẾT HÔM NAY / DAILY SUMMARY");
   SetDailyLabel(1,"Ngày giờ sàn / Server date: "+TimeToString(from,TIME_DATE));
   SetDailyLabel(2,"Số lệnh đã vào / Entry orders: "+IntegerToString(order_count));
   SetDailyLabel(3,"Tổng khối lượng / Total lots: "+DoubleToString(lots,2));
}

void DeleteDailySummary()
{
   for(int r=0;r<4;r++) ObjectDelete(0,DAILY_LABEL_PREFIX+(string)r);
}

//--------------------------- MT5 Events ------------------------------
int OnInit()
{
   string phoneStateKey=PhoneTradingStateKey();
   if(GlobalVariableCheck(phoneStateKey)) g_phone_trading_enabled=(GlobalVariableGet(phoneStateKey)>0.5);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   string reason;
   if(!TradingEnvironmentReady(reason))
      Log("Environment warning: " + reason);

   // Input scale requested by user: 100 units = 10 pips.
   g_initial_stop_distance_pips = InpInitialStopDistanceUnits / 10.0;
   if(g_initial_stop_distance_pips <= 0.0)
      g_initial_stop_distance_pips = 10.0;

   if(InpAddEveryPips<=0 || InpAddFirstAfterPips<=0 ||
      InpMaxPositionsPerCycle<1 || InpMaxBackfillPerPass<1 ||
      InpCycleTakeProfitUSD<0)
      return INIT_PARAMETERS_INCORRECT;

   g_cycle_direction=-1; g_cycle_anchor=0.0; g_last_add_level=0;
   string cycleKey="DTH_"+(string)InpMagic+"_"+_Symbol+"_START";
   if(GlobalVariableCheck(cycleKey))
      g_cycle_start_time=(datetime)GlobalVariableGet(cycleKey);
   CreateControls();
   UpdateDailySummary();
   EventSetMillisecondTimer(250);
   if(InpEnablePhoneBridge && StringLen(InpBridgeToken)<32)
      Log("Phone Bridge disabled: token must contain at least 32 characters.");

   Log("Initialized v1.026 Bridge edition on " + _Symbol +
       " | digits=" + (string)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) +
       " | point=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_POINT), 8) +
       " | tickSize=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8) +
       " | pipSize=" + DoubleToString(PipSize(), 8) +
       " | phoneTrading="+(g_phone_trading_enabled?"ON":"OFF")+
       " | balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
       " | freeMargin=" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteControls();
}

void OnTick()
{
   UpdateDailySummary();
   if(g_busy) return;
   ManagePosition();
}

void OnTimer()
{
   // Timer is a fallback reconciliation path if ticks temporarily stop.
   UpdateDailySummary();
   if(g_busy) return;
   ManagePosition();
   BridgePoll();
}

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == BTN_BUY)
   {
      ObjectSetInteger(0, BTN_BUY, OBJPROP_STATE, false);
      OpenInitialPosition(ORDER_TYPE_BUY);
   }
   else if(sparam == BTN_SELL)
   {
      ObjectSetInteger(0, BTN_SELL, OBJPROP_STATE, false);
      OpenInitialPosition(ORDER_TYPE_SELL);
   }
   else if(sparam == BTN_FLAT)
   {
      ObjectSetInteger(0, BTN_FLAT, OBJPROP_STATE, false);
      CloseAllAndReset();
   }
   else if(sparam == BTN_APPLY)
   {
      ObjectSetInteger(0, BTN_APPLY, OBJPROP_STATE, false);
      ApplyInitialStopDistanceFromChart();
   }
   else if(sparam == BTN_MOVE_STOP)
   {
      ObjectSetInteger(0, BTN_MOVE_STOP, OBJPROP_STATE, false);
      double step_pips = 0.0;
      if(!g_busy && GetMoveStopStepPips(step_pips))
      {
         g_busy = true;
         MoveOppositeStopOneStep(step_pips);
         g_busy = false;
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Reconcile state on the next tick/timer; do not do slow AI/network work here.
   if(trans.symbol == _Symbol)
   {
      Log("Trade transaction received. type=" + (string)trans.type +
          " order=" + (string)trans.order +
          " deal=" + (string)trans.deal);
      g_recovery_required = true;
      // Keep this callback lightweight. OnTick/OnTimer performs the
      // position reconciliation and emergency close sequence.
   }
}
//+------------------------------------------------------------------+
