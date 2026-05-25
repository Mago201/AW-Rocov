//+------------------------------------------------------------------+
//|  Panel.mqh                                                        |
//|  Тестовая панель для ручного управления EA в Strategy Tester.     |
//|                                                                   |
//|  Отвечает только за две вещи:                                     |
//|     1) рисует сетку 3×3 кликабельных OBJ_BUTTON;                  |
//|     2) на CHARTEVENT_OBJECT_CLICK резолвит имя объекта в          |
//|        ENUM_PANEL_BUTTON и снимает «нажатое» состояние кнопки.    |
//|                                                                   |
//|  Никакой торговой логики тут нет — что делать с кодом нажатия,    |
//|  решает EA. Это разделение нужно, чтобы саму панель можно было    |
//|  тестировать и менять, не трогая движок.                          |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_PANEL_MQH__
#define __AWROCOV_PANEL_MQH__

#include "Logger.mqh"

//--- Какая кнопка нажата
enum ENUM_PANEL_BUTTON
  {
   PANEL_BTN_NONE          = 0,   // не наша кнопка / не нажатие
   PANEL_BTN_BUY_SMALL     = 1,   // BUY 0.01
   PANEL_BTN_SELL_SMALL    = 2,   // SELL 0.01
   PANEL_BTN_BUY_BIG       = 3,   // BUY 0.10
   PANEL_BTN_SELL_BIG      = 4,   // SELL 0.10
   PANEL_BTN_CLOSE_ALL     = 5,   // ✖ ЗАКР.
   PANEL_BTN_RESET         = 6,   // × СБРОС
   PANEL_BTN_PAUSE_TOGGLE  = 7,   // ⏸ ПАУЗА / ▶ ВОЗОБН.
   PANEL_BTN_FORCE_TRIGGER = 8,   // ⚡ ТРИГГЕР
   PANEL_BTN_FORCE_BE_HUNT = 9    // → BE-HUNT
  };

class CTestPanel
  {
private:
   long              m_chart_id;
   string            m_prefix;          // префикс имён OBJ_BUTTON
   bool              m_created;
   CLogger          *m_log;

   //--- Геометрия (px)
   int               m_corner;          // ENUM_BASE_CORNER
   int               m_origin_x;        // отступ от угла, X
   int               m_origin_y;        // отступ от угла, Y
   int               m_btn_w;
   int               m_btn_h;
   int               m_gap;

   //--- Имена кнопок (8 фиксированных + динамическая пауза)
   string            BtnName(const string suffix) const
     { return m_prefix + suffix; }

   //--- Создать одну кнопку. Возвращает true при успехе.
   bool              CreateButton(const string  name,
                                  const string  text,
                                  const int     col,
                                  const int     row,
                                  const color   bg,
                                  const color   fg = clrWhite)
     {
      int x, y;
      if(m_corner == CORNER_LEFT_UPPER || m_corner == CORNER_LEFT_LOWER)
         x = m_origin_x + col * (m_btn_w + m_gap);
      else
         x = m_origin_x + (2 - col) * (m_btn_w + m_gap); // зеркалим столбцы для правых углов
      if(m_corner == CORNER_LEFT_UPPER || m_corner == CORNER_RIGHT_UPPER)
         y = m_origin_y + row * (m_btn_h + m_gap);
      else
         y = m_origin_y + (2 - row) * (m_btn_h + m_gap);

      if(!ObjectCreate(m_chart_id, name, OBJ_BUTTON, 0, 0, 0))
        {
         if(m_log)
            m_log.Error(StringFormat("Panel: ObjectCreate(%s) не удалось err=%d",
                                     name, GetLastError()));
         return false;
        }
      ObjectSetInteger(m_chart_id, name, OBJPROP_CORNER,     m_corner);
      ObjectSetInteger(m_chart_id, name, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(m_chart_id, name, OBJPROP_YDISTANCE,  y);
      ObjectSetInteger(m_chart_id, name, OBJPROP_XSIZE,      m_btn_w);
      ObjectSetInteger(m_chart_id, name, OBJPROP_YSIZE,      m_btn_h);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BGCOLOR,    bg);
      ObjectSetInteger(m_chart_id, name, OBJPROP_COLOR,      fg);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(m_chart_id, name, OBJPROP_FONTSIZE,   9);
      ObjectSetInteger(m_chart_id, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BACK,       false);
      ObjectSetInteger(m_chart_id, name, OBJPROP_STATE,      false);
      ObjectSetString (m_chart_id, name, OBJPROP_FONT,       "Tahoma");
      ObjectSetString (m_chart_id, name, OBJPROP_TEXT,       text);
      return true;
     }

public:
                     CTestPanel():
                        m_chart_id(0),
                        m_prefix("AWRocov_btn_"),
                        m_created(false),
                        m_log(NULL),
                        m_corner(CORNER_RIGHT_UPPER),
                        m_origin_x(10),
                        m_origin_y(30),
                        m_btn_w(100),
                        m_btn_h(24),
                        m_gap(4) {}

   void              Init(const long  chart_id,
                          const string prefix,
                          CLogger     *logger,
                          const int    corner,
                          const int    origin_x,
                          const int    origin_y)
     {
      m_chart_id = chart_id;
      m_prefix   = (StringLen(prefix) > 0) ? prefix : "AWRocov_btn_";
      m_log      = logger;
      m_corner   = corner;
      m_origin_x = origin_x;
      m_origin_y = origin_y;
     }

   //--- Создать все 9 кнопок. Если уже создано — пересоздаём,
   //    чтобы пережить смену параметров через input.
   bool              Create()
     {
      Destroy();

      // Цвета подобраны так, чтобы легко различать секции глазом
      // на типичных тёмных и светлых темах графика:
      //   зелёное   — открытие BUY
      //   красное   — открытие SELL
      //   фиолет    — пауза
      //   золото    — форс-триггер
      //   оранжевое — закрытие
      //   синее     — сброс
      //   бирюза    — переход в BE-охоту
      bool ok = true;
      ok &= CreateButton(BtnName("buy_small"),     "BUY 0.01",   0, 0, clrSeaGreen);
      ok &= CreateButton(BtnName("sell_small"),    "SELL 0.01",  1, 0, clrFireBrick);
      ok &= CreateButton(BtnName("pause"),         "ПАУЗА",      2, 0, clrMediumPurple);

      ok &= CreateButton(BtnName("buy_big"),       "BUY 0.10",   0, 1, clrSeaGreen);
      ok &= CreateButton(BtnName("sell_big"),      "SELL 0.10",  1, 1, clrFireBrick);
      ok &= CreateButton(BtnName("force_trigger"), "ТРИГГЕР",    2, 1, clrGoldenrod);

      ok &= CreateButton(BtnName("close_all"),     "ЗАКР. ВСЁ",  0, 2, clrDarkOrange);
      ok &= CreateButton(BtnName("reset"),         "СБРОС",      1, 2, clrSteelBlue);
      ok &= CreateButton(BtnName("force_be_hunt"), "ПОИСК BE",   2, 2, clrTeal);

      ChartRedraw(m_chart_id);
      m_created = ok;
      if(m_log)
        {
         if(ok) m_log.Info("Panel: 9 кнопок создано");
         else   m_log.Error("Panel: создание кнопок частично не удалось");
        }
      return ok;
     }

   //--- Снести все наши объекты с графика
   void              Destroy()
     {
      if(m_chart_id == 0) return;
      // Удаляем по префиксу — ловим всё наше за один вызов.
      ObjectsDeleteAll(m_chart_id, m_prefix);
      ChartRedraw(m_chart_id);
      m_created = false;
     }

   bool              IsCreated() const { return m_created; }

   //--- Обновить подпись кнопки паузы (вызывает EA при смене состояния)
   void              SetPauseCaption(const bool paused)
     {
      string name = BtnName("pause");
      string text = paused ? "ВОЗОБН." : "ПАУЗА";
      color  bg   = paused ? clrDimGray : clrMediumPurple;
      ObjectSetString (m_chart_id, name, OBJPROP_TEXT,    text);
      ObjectSetInteger(m_chart_id, name, OBJPROP_BGCOLOR, bg);
     }

   //--- Резолв CHARTEVENT_OBJECT_CLICK -> ENUM_PANEL_BUTTON.
   //    Также снимает «нажатое» состояние кнопки, чтобы повторный
   //    клик гарантированно сработал.
   ENUM_PANEL_BUTTON OnEvent(const int      id,
                             const long    &lparam,
                             const double  &dparam,
                             const string  &sparam)
     {
      if(id != CHARTEVENT_OBJECT_CLICK) return PANEL_BTN_NONE;
      if(StringFind(sparam, m_prefix) != 0) return PANEL_BTN_NONE;

      // Снимаем «depressed» состояние сразу, чтобы кнопка вернулась
      // к нормальному виду; это безопасно даже если объект уже удалён.
      ObjectSetInteger(m_chart_id, sparam, OBJPROP_STATE, false);

      string suffix = StringSubstr(sparam, StringLen(m_prefix));
      if(suffix == "buy_small")     return PANEL_BTN_BUY_SMALL;
      if(suffix == "sell_small")    return PANEL_BTN_SELL_SMALL;
      if(suffix == "buy_big")       return PANEL_BTN_BUY_BIG;
      if(suffix == "sell_big")      return PANEL_BTN_SELL_BIG;
      if(suffix == "close_all")     return PANEL_BTN_CLOSE_ALL;
      if(suffix == "reset")         return PANEL_BTN_RESET;
      if(suffix == "pause")         return PANEL_BTN_PAUSE_TOGGLE;
      if(suffix == "force_trigger") return PANEL_BTN_FORCE_TRIGGER;
      if(suffix == "force_be_hunt") return PANEL_BTN_FORCE_BE_HUNT;
      return PANEL_BTN_NONE;
     }
  };

#endif // __AWROCOV_PANEL_MQH__
