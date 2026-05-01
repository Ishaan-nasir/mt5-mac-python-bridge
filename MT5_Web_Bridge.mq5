//+------------------------------------------------------------------+
//|                                              MT5_Web_Bridge.mq5  |
//|                        TIS HTTP Bridge for Execution Automation  |
//+------------------------------------------------------------------+
#property copyright "Trading Intelligence System"
#property link      ""
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;
string BASE_URL = "http://127.0.0.1:8000";
datetime last_m15_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(234000);
    // Note: You must add "http://localhost:8000" or "http://localhost" to allowed WebRequest URLs in Tools -> Options -> Expert Advisors
    
    EventSetMillisecondTimer(500); 
    Print("Native Web Bridge Initialized. Polling /command every 500ms.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Print("Native Web Bridge Deinitialized.");
}

//+------------------------------------------------------------------+
//| Helper for WebRequests                                           |
//+------------------------------------------------------------------+
string PostRequest(string endpoint, string json_payload)
{
    char post[], result[];
    string result_headers;
    string headers = "Content-Type: application/json\r\n";
    StringToCharArray(json_payload, post, 0, WHOLE_ARRAY, CP_UTF8);
    int size = ArraySize(post)-1;
    if(size < 0) size = 0;
    ArrayResize(post, size);
    
    int res = WebRequest("POST", BASE_URL + endpoint, headers, 1000, post, result, result_headers);
    if(res > 0) return CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
    return "";
}

string GetRequest(string endpoint)
{
    char post[], result[];
    string result_headers;
    string headers = "";
    int res = WebRequest("GET", BASE_URL + endpoint, headers, 1000, post, result, result_headers);
    if(res > 0) return CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
    return "";
}

//+------------------------------------------------------------------+
//| SendAccountState — posts live account snapshot to /state         |
//+------------------------------------------------------------------+
void SendAccountState()
{
    // ── Account metrics ───────────────────────────────────────
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double margin  = AccountInfoDouble(ACCOUNT_MARGIN);

    // ── Sum floating P&L across all open positions ──────────────
    double floating_pnl = 0.0;
    int    total_pos    = PositionsTotal();
    for(int i = 0; i < total_pos; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0)
            floating_pnl += PositionGetDouble(POSITION_PROFIT);
    }

    // ── Build JSON payload ────────────────────────────────
    string payload = StringFormat(
        "{\"balance\":%s,\"equity\":%s,\"margin\":%s,"
        "\"floating_pnl\":%s,\"open_positions\":%d,"
        "\"timestamp\":%d}",
        DoubleToString(balance,      2),
        DoubleToString(equity,       2),
        DoubleToString(margin,       2),
        DoubleToString(floating_pnl, 2),
        total_pos,
        (int)TimeCurrent()
    );

    PostRequest("/state", payload);
}

//+------------------------------------------------------------------+
//| Helper to parse simple JSON                                      |
//+------------------------------------------------------------------+
string ExtractJsonString(string json, string key)
{
    string search = "\"" + key + "\":\"";
    int start = StringFind(json, search);
    if(start == -1) return "";
    start += StringLen(search);
    int end = StringFind(json, "\"", start);
    if(end == -1) return "";
    return StringSubstr(json, start, end - start);
}

double ExtractJsonDouble(string json, string key)
{
    string search = "\"" + key + "\":";
    int start = StringFind(json, search);
    if(start == -1) return 0.0;
    start += StringLen(search);
    int end = StringFind(json, ",", start);
    if(end == -1) end = StringFind(json, "}", start);
    if(end == -1) return 0.0;
    return StringToDouble(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| SendCandleData helper                                            |
//+------------------------------------------------------------------+
void SendCandleData()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   // Copy the last 50 candles on the M15 timeframe
   int copied = CopyRates(_Symbol, PERIOD_M15, 0, 50, rates);
   
   if(copied <= 0) 
     {
      Print("Failed to copy rates. Error: ", GetLastError());
      return;
     }

   // Manually build the JSON string
   string json = "{\"symbol\":\"" + _Symbol + "\", \"timeframe\":\"M15\", \"candles\":[";
   
   for(int i = 0; i < copied; i++) 
     {
      // Pillar 1 (2026-04-22): tick_volume added for volume_delta primitive.
      // Python side reads this as 'tick_volume' column in the DataFrame.
      json += StringFormat("{\"time\":%d, \"open\":%f, \"high\":%f, \"low\":%f, \"close\":%f, \"tick_volume\":%d}",
                           rates[i].time, rates[i].open, rates[i].high, rates[i].low, rates[i].close,
                           (int)rates[i].tick_volume);
      
      // Add a comma after every candle EXCEPT the last one
      if(i < copied - 1) json += ",";
     }
   json += "]}";

   // Prepare the WebRequest
   char post_data[];
   char result[];
   string result_headers;
   StringToCharArray(json, post_data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(post_data, ArraySize(post_data)-1);
   
   string headers = "Content-Type: application/json\r\n";
   
   // Fire the payload to the new /candles endpoint
   int res = WebRequest("POST", "http://127.0.0.1:8000/candles", headers, 5000, post_data, result, result_headers);
   
   if(res != 200) Print("Candle Post Failed! Error: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // --- NEW BAR DETECTION ---
    datetime current_m15 = iTime(_Symbol, PERIOD_M15, 0);
    
    if(current_m15 != last_m15_time) 
      {
       if(last_m15_time != 0) // Prevents firing instantly when you first drop it on the chart
         {
          Print(">>> New M15 Candle Detected! Sending Data Pipeline...");
          SendCandleData();
         }
       last_m15_time = current_m15;
      }

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    string payload = "{\"symbol\":\"" + _Symbol + "\",\"bid\":" + DoubleToString(bid, _Digits) + ",\"ask\":" + DoubleToString(ask, _Digits) + "}";
    PostRequest("/tick", payload);
}

//+------------------------------------------------------------------+
//| Timer function for evaluating commands                           |
//+------------------------------------------------------------------+
void OnTimer()
{
    // ── Dual-cadence tick counter ──────────────────────────────
    // Timer fires every 500ms. We use a static counter so that:
    //   - GET /command fires every tick (500ms)
    //   - SendAccountState fires every 2nd tick (1000ms)
    // This avoids MQL5's single-timer-per-EA limitation.
    static int timer_tick = 0;
    timer_tick++;

    // ── /command polling (every 500ms) ────────────────────────
    string response = GetRequest("/command");
    if(response != "" && StringFind(response, "NONE") == -1)
    {
        string action = ExtractJsonString(response, "action");
        if(action == "BUY" || action == "SELL")
        {
            string target_symbol = ExtractJsonString(response, "symbol");
            double lot_size = ExtractJsonDouble(response, "lot_size");
            double sl = ExtractJsonDouble(response, "sl");
            double tp = ExtractJsonDouble(response, "tp");
            
            bool order_ok = false;
            if(action == "BUY") order_ok = trade.Buy(lot_size, target_symbol, 0, sl, tp);
            else if(action == "SELL") order_ok = trade.Sell(lot_size, target_symbol, 0, sl, tp);
            
            uint retcode = trade.ResultRetcode();
            ulong ticket = trade.ResultOrder();
            
            string statusStr = order_ok ? "OK" : "ERROR";
            string resPayload = "{\"status\":\"" + statusStr + "\",\"ticket\":" + IntegerToString(ticket) + ",\"retcode\":" + IntegerToString(retcode) + ",\"action\":\"" + action + "\",\"symbol\":\"" + target_symbol + "\"}";
            PostRequest("/result", resPayload);
        }
    }

    // ── Account state sync (every 1000ms = every 2nd 500ms tick) ─
    if(timer_tick % 2 == 0)
        SendAccountState();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — Pillar 3: Reflection Engine Trigger         |
//|                                                                  |
//| Fires on every trade event from the MT5 trade server.           |
//| We filter for TRADE_TRANSACTION_DEAL_ADD with DEAL_ENTRY_OUT    |
//| (full close) or DEAL_ENTRY_INOUT (partial/reverse close).       |
//|                                                                  |
//| On detection, extracts:                                          |
//|   deal_position_id → maps to Python ticket_id in trade_ledger   |
//|   deal_symbol      → e.g. "XAUUSD"                              |
//|   deal_profit      → final realised P&L in account currency     |
//|                                                                  |
//| POSTs to /result with the exact TradeResult schema:             |
//|   {"status":"OK","action":"CLOSE","ticket":<id>,                |
//|    "symbol":"<sym>","final_pnl":<pnl>}                          |
//|                                                                  |
//| This triggers write_trade_journal() + Graph-RAG reindex in the  |
//| Python Reflection Engine (memory/journal_writer.py).            |
//+------------------------------------------------------------------+
void OnTradeTransaction(
    const MqlTradeTransaction& trans,
    const MqlTradeRequest&     request,
    const MqlTradeResult&      result)
{
    // Only act on confirmed deal additions
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;

    // Select the deal to read its properties
    if(!HistoryDealSelect(trans.deal))
        return;

    // Only fire for exit deals (full close or partial/reverse)
    ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
        return;

    // ── Extract deal fields ───────────────────────────────────
    // DEAL_POSITION_ID matches the position ticket stored in trade_ledger.db
    ulong  position_id = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
    string deal_symbol = HistoryDealGetString(trans.deal,  DEAL_SYMBOL);
    double deal_profit = HistoryDealGetDouble(trans.deal,  DEAL_PROFIT);

    // Guard: skip if symbol or position_id missing
    if(deal_symbol == "" || position_id == 0)
        return;

    Print(StringFormat(
        "[BRIDGE] Position closed — ticket=%llu sym=%s pnl=%.2f",
        position_id, deal_symbol, deal_profit
    ));

    // ── Build Pillar 3 /result payload ───────────────────────
    // Matches Python TradeResult schema exactly:
    //   status, action, ticket, symbol, final_pnl
    string closePayload = StringFormat(
        "{\"status\":\"OK\",\"action\":\"CLOSE\","
        "\"ticket\":%llu,\"symbol\":\"%s\",\"final_pnl\":%.2f}",
        position_id,
        deal_symbol,
        deal_profit
    );

    // ── POST to /result — triggers Reflection Engine ─────────
    string postResult = PostRequest("/result", closePayload);
    if(postResult != "")
        Print("[BRIDGE] Reflection Engine ACK: ", postResult);
    else
        Print("[BRIDGE] WARNING: /result POST failed for ticket=", position_id);
}
//+------------------------------------------------------------------+
