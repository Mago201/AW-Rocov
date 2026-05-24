//+------------------------------------------------------------------+
//|  Logger.mqh                                                       |
//|  Лёгкий логгер с префиксом для AW-Rocov                           |
//+------------------------------------------------------------------+
#ifndef __AWROCOV_LOGGER_MQH__
#define __AWROCOV_LOGGER_MQH__

enum ENUM_LOG_LEVEL
  {
   LOG_DEBUG = 0,   // отладка
   LOG_INFO  = 1,   // информация
   LOG_WARN  = 2,   // предупреждение
   LOG_ERROR = 3    // ошибка
  };

class CLogger
  {
private:
   string            m_prefix;
   ENUM_LOG_LEVEL    m_min_level;

   string            LevelTag(ENUM_LOG_LEVEL lvl) const
     {
      switch(lvl)
        {
         case LOG_DEBUG: return "ОТЛ";
         case LOG_INFO:  return "ИНФ";
         case LOG_WARN:  return "ПРЕ";
         case LOG_ERROR: return "ОШБ";
        }
      return "?";
     }

public:
                     CLogger(): m_prefix("AWRocov"), m_min_level(LOG_INFO) {}

   void              Init(const string prefix, const ENUM_LOG_LEVEL min_level)
     {
      m_prefix    = prefix;
      m_min_level = min_level;
     }

   void              Log(ENUM_LOG_LEVEL lvl, const string msg)
     {
      if(lvl < m_min_level)
         return;
      PrintFormat("[%s][%s] %s", m_prefix, LevelTag(lvl), msg);
     }

   void              Debug(const string msg) { Log(LOG_DEBUG, msg); }
   void              Info (const string msg) { Log(LOG_INFO,  msg); }
   void              Warn (const string msg) { Log(LOG_WARN,  msg); }
   void              Error(const string msg) { Log(LOG_ERROR, msg); }
  };

#endif // __AWROCOV_LOGGER_MQH__
