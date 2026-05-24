//+------------------------------------------------------------------+
//|  ButtonTest.mq5  v2                                               |
//|  Цель: однозначно понять, почему "кнопка нажимается но ордер     |
//|  не открывается". Имеет ТРИ независимых пути, чтобы исключить    |
//|  любой класс ошибок:                                             |
//|                                                                   |
//|   1. AUTO    — через InpAutoFireSec секунд после старта EA сам   |
//|                 отправляет OrderSend, без всяких кликов.          |
//|                 Если сделка проходит — торговля работает.        |
//|   2. POLL    — на каждом тике читаем OBJPROP_STATE кнопки.        |
//|                 Если она true (была нажата) — обрабатываем как   |
//|                 клик. Спасает в случаях, когда                   |
//|                 CHARTEVENT_OBJECT_CLICK не доставляется.          |
//|   3. EVENT   — стандартный OnChartEvent. Самый «правильный» путь,|
//|                 но может не сработать при глюке тестера.         |
//|                                                                   |
//|  Поведение виден в Comment(): счётчики путей и last result.      |
//+------------------------------------------------------------------+
#property copyright "AW-Rocov diag"
#property version   "2.00"
#property strict
#property description "Тест: AUTO (через 5 сек) + POLL (опрос на тике) + EVENT (CHARTEVENT_OBJECT_CLICK)."

input double InpLot         = 0.01;     // лот
input ulong  InpMagic       = 99999;    // magic
input int    InpAutoFireSec = 5;        // через сколько секунд авто-выстрел (0 = выключить)

const string g_btn = "ButtonTest_BUY";

int      g_clicks_event = 0;     // клики, пойманные через CHARTEVENT_OBJECT_CLICK
int      g_clicks_poll  = 0;     // клики, пойманные через OBJPROP_STATE
bool     g_auto_done    = false;
datetime g_start_time   = 0;
string   g_last_event   = "—";
string   g_last_poll    = "—";
string   g_last_auto    = "—";

//+------------------------------------------------------------------+
//| Универсальный отправитель рыночного ордера. Возвращает текст     |
//| с retcode/order или ошибкой.                                     |
//+------------------------------------------------------------------+
string SendBuy(const string source)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.ask <= 0.0)
      return "SymbolInfoTick FAIL";

   MqlTradeRequest req; ZeroMemory(req);
   MqlTradeResult  res; ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = InpLot;
   req.type         = ORDER_TYPE_BUY;
   req.price        = t.ask;
   req.deviation    = 30;
   req.magic        = InpMagic;
   req.comment      = "ButtonTest:" + source;
   req.type_time    = ORDER_TIME_GTC;

   ENUM_ORDER_TYPE_FILLING fills[3] = {ORDER_FILLING_IOC, ORDER_FILLING_FOK, ORDER_FILLING_RETURN};
   for(int i = 0; i < 3; i++)
     {
      req.type_filling = fills[i];
      ZeroMemory(res);
      ResetLastError();
      bool sent = OrderSend(req, res);
      PrintFormat("[ButtonTest][%s] OrderSend filling=%d sent=%d retcode=%u (%s) order=%I64u err=%d",
                  source, fills[i], sent, res.retcode, res.comment, res.order, GetLastError());
      if(sent && (res.retcode == TRADE_RETCODE_DONE ||
                  res.retcode == TRADE_RETCODE_PLACED))
         return StringFormat("OK order=%I64u retcode=%u", res.order, res.retcode);
      if(res.retcode != TRADE_RETCODE_INVALID_FILL && res.retcode != 0)
         return StringFormat("FAIL retcode=%u (%s)", res.retcode, res.comment);
     }
   return StringFormat("FAIL retcode=%u (%s)", res.retcode, res.comment);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_start_time = TimeCurrent();

   // Кнопка — большая, в нижнем-левом углу, заведомо над шкалой.
   ObjectDelete(0, g_btn);
   ObjectCreate(0, g_btn, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, g_btn, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(0, g_btn, OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, g_btn, OBJPROP_YDISTANCE, 200);
   ObjectSetInteger(0, g_btn, OBJPROP_XSIZE,     180);
   ObjectSetInteger(0, g_btn, OBJPROP_YSIZE,     50);
   ObjectSetString (0, g_btn, OBJPROP_TEXT,      "TEST BUY  0.01");
   ObjectSetInteger(0, g_btn, OBJPROP_BGCOLOR,   C'40,140,70');
   ObjectSetInteger(0, g_btn, OBJPROP_COLOR,     clrWhite);
   ObjectSetInteger(0, g_btn, OBJPROP_FONTSIZE,  14);
   ObjectSetInteger(0, g_btn, OBJPROP_BACK,      false);
   ObjectSetInteger(0, g_btn, OBJPROP_HIDDEN,    true);
   ObjectSetInteger(0, g_btn, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, g_btn, OBJPROP_STATE,     false);

   PrintFormat("[ButtonTest] OnInit symbol=%s | term_trade=%d mql_trade=%d acc_trade=%d "
               "visual=%d tester=%d optim=%d | auto_fire_sec=%d",
               _Symbol,
               (int)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
               (int)MQLInfoInteger(MQL_TRADE_ALLOWED),
               (int)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED),
               (int)MQLInfoInteger(MQL_VISUAL_MODE),
               (int)MQLInfoInteger(MQL_TESTER),
               (int)MQLInfoInteger(MQL_OPTIMIZATION),
               InpAutoFireSec);

   ChartRedraw(0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0, g_btn);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Путь EVENT — штатный.                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int       id,
                  const long     &lparam,
                  const double   &dparam,
                  const string   &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   PrintFormat("[ButtonTest][EVENT] CLICK sparam=%s", sparam);

   if(sparam == g_btn)
     {
      g_clicks_event++;
      g_last_event = SendBuy("event");
      ObjectSetInteger(0, g_btn, OBJPROP_STATE, false);
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
//| Пути POLL и AUTO — оба в OnTick.                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   // === POLL: ловим клик через OBJPROP_STATE ===
   bool state = (bool)ObjectGetInteger(0, g_btn, OBJPROP_STATE);
   if(state)
     {
      g_clicks_poll++;
      ObjectSetInteger(0, g_btn, OBJPROP_STATE, false);
      ChartRedraw(0);
      g_last_poll = SendBuy("poll");
     }

   // === AUTO: однократный авто-выстрел через N секунд ===
   if(InpAutoFireSec > 0 && !g_auto_done &&
      (TimeCurrent() - g_start_time) >= InpAutoFireSec)
     {
      g_auto_done = true;
      g_last_auto = SendBuy("auto");
     }

   // === Status overlay ===
   string s = StringFormat(
      "ButtonTest v2 | %s\n"
      "EVENT clicks: %d   last: %s\n"
      "POLL  clicks: %d   last: %s\n"
      "AUTO  done:   %s   last: %s\n"
      "(жми TEST BUY; через %d сек EA сам выстрелит ордером)",
      _Symbol,
      g_clicks_event, g_last_event,
      g_clicks_poll,  g_last_poll,
      g_auto_done ? "yes" : "no", g_last_auto,
      InpAutoFireSec);
   Comment(s);
  }
//+------------------------------------------------------------------+
