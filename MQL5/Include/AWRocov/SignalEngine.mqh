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
                                      m_h_atr(INVALID_HANDLE) {}

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

      if(m_log)
         m_log.Info(StringFormat(
            "SignalEngine: EMA(%d/%d) RSI(%d) [%.0f/%.0f] ATR(%d) tf=%s shift=%d",
            cfg.ema_fast_period, cfg.ema_slow_period,
            cfg.rsi_period, cfg.rsi_buy_level, cfg.rsi_sell_level,
            cfg.atr_period, EnumToString(tf), cfg.signal_shift));
      return true;
     }

   void              Release()
     {
      if(m_h_ema_fast != INVALID_HANDLE) IndicatorRelease(m_h_ema_fast);
      if(m_h_ema_slow != INVALID_HANDLE) IndicatorRelease(m_h_ema_slow);
      if(m_h_rsi      != INVALID_HANDLE) IndicatorRelease(m_h_rsi);
      if(m_h_atr      != INVALID_HANDLE) IndicatorRelease(m_h_atr);
      m_h_ema_fast = m_h_ema_slow = m_h_rsi = m_h_atr = INVALID_HANDLE;
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

      if(trend > 0 && rsi <= m_cfg.rsi_buy_level)  return  1; // откат вверх в аптренде
      if(trend < 0 && rsi >= m_cfg.rsi_sell_level) return -1; // откат вниз в даунтренде
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
  };

#endif // __AWROCOV_SIGNALENGINE_MQH__
