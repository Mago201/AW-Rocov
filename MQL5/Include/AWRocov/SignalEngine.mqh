//+------------------------------------------------------------------+
//|  SignalEngine.mqh                                                 |
//|  Генерация входных сигналов для скальпера AWScalper.              |
//|                                                                   |
//|  Логика (тренд + откат), оптимизирована под XAUUSD M1/M5:         |
//|    1. Тренд-фильтр: EMA(fast) против EMA(slow).                    |
//|         emaF > emaS  => восходящий контекст (ищем только BUY)     |
//|         emaF < emaS  => нисходящий контекст (ищем только SELL)     |
//|    2. Вход по откату RSI внутрь тренда (контр-импульсный вход,     |
//|       даёт высокий винрейт на мелком TP — то, что нужно для        |
//|       мартингейл-цикла):                                          |
//|         тренд вверх + RSI <= нижний порог  => BUY                 |
//|         тренд вниз  + RSI >= верхний порог  => SELL                |
//|    3. ATR используется внешним движком для расчёта TP/SL в         |
//|       пунктах (адаптивные таргеты под текущую волатильность).      |
//|                                                                   |
//|  Все значения берутся с последнего ЗАКРЫТОГО бара (shift = 1),     |
//|  поэтому сигнал не «перерисовывается» внутри формирующегося бара.  |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_SIGNALENGINE_MQH__
#define __AWROCOV_SIGNALENGINE_MQH__

#include "Logger.mqh"

struct SSignalConfig
  {
   int     ema_fast_period;   // период быстрой EMA (тренд)
   int     ema_slow_period;   // период медленной EMA (тренд)
   int     rsi_period;        // период RSI
   double  rsi_buy_level;     // RSI <= этого уровня в аптренде => BUY
   double  rsi_sell_level;    // RSI >= этого уровня в даунтренде => SELL
   int     atr_period;        // период ATR (для адаптивных таргетов)
   int     signal_shift;      // бар, с которого читаем (1 = последний закрытый)
   //--- WPR (Williams %R) — опциональное подтверждение входа.
   //    Диапазон WPR: [-100..0]. Перепроданность ~ -80, перекупленность ~ -20.
   bool    use_wpr;           // включить фильтр WPR
   int     wpr_period;        // период WPR
   double  wpr_buy_level;     // WPR <= уровня (перепроданность) подтверждает BUY
   double  wpr_sell_level;    // WPR >= уровня (перекупленность) подтверждает SELL
  };

class CSignalEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   SSignalConfig     m_cfg;
   CLogger          *m_log;

   int               m_h_ema_fast;
   int               m_h_ema_slow;
   int               m_h_rsi;
   int               m_h_atr;
   int               m_h_wpr;

   //--- Прочитать одно значение буфера индикатора на заданном сдвиге.
   bool              ReadOne(const int handle, const int shift, double &out) const
     {
      double buf[];
      if(handle == INVALID_HANDLE) return false;
      if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return false;
      out = buf[0];
      return true;
     }

public:
                     CSignalEngine(): m_log(NULL),
                                      m_h_ema_fast(INVALID_HANDLE),
                                      m_h_ema_slow(INVALID_HANDLE),
                                      m_h_rsi(INVALID_HANDLE),
                                      m_h_atr(INVALID_HANDLE),
                                      m_h_wpr(INVALID_HANDLE) {}

   bool              Init(const string         symbol,
                          const ENUM_TIMEFRAMES tf,
                          const SSignalConfig  &cfg,
                          CLogger              *logger)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_cfg    = cfg;
      m_log    = logger;

      m_h_ema_fast = iMA(symbol, tf, cfg.ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
      m_h_ema_slow = iMA(symbol, tf, cfg.ema_slow_period, 0, MODE_EMA, PRICE_CLOSE);
      m_h_rsi      = iRSI(symbol, tf, cfg.rsi_period, PRICE_CLOSE);
      m_h_atr      = iATR(symbol, tf, cfg.atr_period);

      if(m_h_ema_fast == INVALID_HANDLE ||
         m_h_ema_slow == INVALID_HANDLE ||
         m_h_rsi      == INVALID_HANDLE ||
         m_h_atr      == INVALID_HANDLE)
        {
         if(m_log) m_log.Error("SignalEngine: не удалось создать хендлы индикаторов");
         return false;
        }

      // WPR создаём только если включён фильтр.
      if(cfg.use_wpr)
        {
         m_h_wpr = iWPR(symbol, tf, cfg.wpr_period);
         if(m_h_wpr == INVALID_HANDLE)
           {
            if(m_log) m_log.Error("SignalEngine: не удалось создать хендл WPR");
            return false;
           }
        }

      if(m_log)
         m_log.Info(StringFormat(
            "SignalEngine: EMA(%d/%d) RSI(%d) [%.0f/%.0f] ATR(%d) WPR=%s tf=%s shift=%d",
            cfg.ema_fast_period, cfg.ema_slow_period,
            cfg.rsi_period, cfg.rsi_buy_level, cfg.rsi_sell_level,
            cfg.atr_period,
            cfg.use_wpr ? StringFormat("вкл(%d)[%.0f/%.0f]", cfg.wpr_period,
                                       cfg.wpr_buy_level, cfg.wpr_sell_level)
                        : "выкл",
            EnumToString(tf), cfg.signal_shift));
      return true;
     }

   void              Release()
     {
      if(m_h_ema_fast != INVALID_HANDLE) IndicatorRelease(m_h_ema_fast);
      if(m_h_ema_slow != INVALID_HANDLE) IndicatorRelease(m_h_ema_slow);
      if(m_h_rsi      != INVALID_HANDLE) IndicatorRelease(m_h_rsi);
      if(m_h_atr      != INVALID_HANDLE) IndicatorRelease(m_h_atr);
      if(m_h_wpr      != INVALID_HANDLE) IndicatorRelease(m_h_wpr);
      m_h_ema_fast = m_h_ema_slow = m_h_rsi = m_h_atr = INVALID_HANDLE;
      m_h_wpr = INVALID_HANDLE;
     }

   //--- Сигнал: +1 (BUY), -1 (SELL), 0 (нет входа / данные не готовы).
   int               GetSignal()
     {
      double emaF, emaS, rsi;
      int s = m_cfg.signal_shift;
      if(!ReadOne(m_h_ema_fast, s, emaF)) return 0;
      if(!ReadOne(m_h_ema_slow, s, emaS)) return 0;
      if(!ReadOne(m_h_rsi,      s, rsi))  return 0;

      int trend = 0;
      if(emaF > emaS) trend =  1;
      else if(emaF < emaS) trend = -1;

      // Опциональное подтверждение по WPR (перепроданность/перекупленность).
      bool wpr_buy_ok  = true;
      bool wpr_sell_ok = true;
      if(m_cfg.use_wpr)
        {
         double wpr;
         if(!ReadOne(m_h_wpr, s, wpr)) return 0;
         wpr_buy_ok  = (wpr <= m_cfg.wpr_buy_level);   // перепроданность -> подтверждаем BUY
         wpr_sell_ok = (wpr >= m_cfg.wpr_sell_level);  // перекупленность -> подтверждаем SELL
        }

      if(trend > 0 && rsi <= m_cfg.rsi_buy_level  && wpr_buy_ok)  return  1; // откат вверх в аптренде
      if(trend < 0 && rsi >= m_cfg.rsi_sell_level && wpr_sell_ok) return -1; // откат вниз в даунтренде
      return 0;
     }

   //--- Текущий ATR, переведённый в пункты символа (0 при ошибке).
   double            GetATRPoints()
     {
      double atr;
      if(!ReadOne(m_h_atr, m_cfg.signal_shift, atr)) return 0.0;
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0) return 0.0;
      return atr / point;
     }

   //--- Текущее направление тренда по EMA: +1 / -1 / 0.
   int               TrendDirection()
     {
      double emaF, emaS;
      int s = m_cfg.signal_shift;
      if(!ReadOne(m_h_ema_fast, s, emaF)) return 0;
      if(!ReadOne(m_h_ema_slow, s, emaS)) return 0;
      if(emaF > emaS) return  1;
      if(emaF < emaS) return -1;
      return 0;
     }

   //--- Текущее значение RSI (для статусной плашки); -1.0 при ошибке.
   double            CurrentRSI()
     {
      double rsi;
      if(!ReadOne(m_h_rsi, m_cfg.signal_shift, rsi)) return -1.0;
      return rsi;
     }

   //--- Текущее значение WPR (для статусной плашки); +1.0 при ошибке/выкл
   //    (валидный диапазон WPR [-100..0], так что +1.0 — заведомо «нет данных»).
   double            CurrentWPR()
     {
      if(!m_cfg.use_wpr) return 1.0;
      double wpr;
      if(!ReadOne(m_h_wpr, m_cfg.signal_shift, wpr)) return 1.0;
      return wpr;
     }
  };

#endif // __AWROCOV_SIGNALENGINE_MQH__
