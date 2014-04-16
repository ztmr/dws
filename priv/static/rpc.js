/* XXX: This is a highly stripped version of the legacy IWF.Server!
 *      You should look for something better :-)
 */

// Imported from IWF.Lib
uuid = function () {
    var delim = "-";
    var S4 = function () {
      return (((1 + Math.random ()) * 0x10000) | 0).toString (16).substring (1);
    }
    return (S4() + S4() + delim +
            S4() + delim +
            S4() + delim +
            S4() + delim +
            S4() + S4() + S4());
  };

RPC = {
  m_WebSock: null,
  m_CoreUrl: null,
  m_PingInterval: 30000,  // 30s in miliseconds
  m_CallTimeOut:  10000,  // 10s in miliseconds
  m_CallBackTable: {},
  m_LockTable: {},
  m_IsInit: false,
  m_ReconnectCtr: 1,

  init: function (url) {
    if (this.m_IsInit) return;
    this.m_IsInit = true;
    this.m_CoreUrl = url;
    this.login ();
  },

  is_connected: function () {
    var me = this;
    return me.m_WebSock.readyState == me.m_WebSock.OPEN;
  },

  login: function () {
    var me = this;
    me.m_WebSock = new WebSocket (me.m_CoreUrl);
    me.m_WebSock.onmessage = me.handle_incoming.bind (this);
    me.m_WebSock.onopen = me.handle_open.bind (this);
    me.m_WebSock.onclose = me.handle_close.bind (this);
  },

  handle_open: function () {
    var me = this;
    me.pinger ();
    me.m_ReconnectCtr = 1;
  },

  handle_close: function () {
    var me = this;
    setTimeout (me.login, me.m_ReconnectCtr*1000);
    if (me.m_ReconnectCtr < 30) me.m_ReconnectCtr <<= 1;
  },

  logout: function () {
    var me = this;
    me.m_WebSock.close ();
  },

  call: function (NameSpace, Method, Arguments, CallBack) {
    var me = this;
    Cmd = { service: NameSpace, call: Method, args: Arguments },
    me.dispatch_call_ (Cmd, CallBack);
  },

  ping: function (CallBack) {
    var me = this;
    me.dispatch_call_ ({ service: 'DWS.Example', call: 'ping' }, CallBack);
  },

  dispatch_call_: function (MsgObj, CallBack, DisableServerLogging) {
    var me = this;
    var id = uuid ();

    var Send = function () {
      if (!me.is_connected ()) return false;
      MsgObj.id = id;
      DisableServerLogging = DisableServerLogging || false;
      try {
        var msg = JSON.stringify (MsgObj);
        me.m_CallBackTable [id] = {
          callback: CallBack, time: Date.now (),
          disable_logging: DisableServerLogging
        };
        me.m_WebSock.send (msg);
        return true;
      }
      catch (e) {
        return false;
      }
    };
    if (!Send ()) setTimeout (Send, 1000); // try later
  },

  cleanup_callbacks_: function () {
    var me = this;
    for (var id in me.m_CallBackTable) {
      var x = me.m_CallBackTable [id];
      if (x.time < (Date.now () - me.m_CallTimeOut))
        delete me.m_CallBackTable [id];
    }
  },

  handle_incoming: function (event) {
    var me  = this;
    var msg = JSON.parse (event.data);
    var cbk = me.m_CallBackTable [msg.id];
    if (cbk) {
      if (typeof (cbk.callback) == 'function') cbk.callback (msg);
      delete me.m_CallBackTable [msg.id];
    }
    me.cleanup_callbacks_ ();
  },

  pinger: function () {
    var me = this;
    setInterval (function () {
        me.ping (function (msg) {
        });
      }, me.m_PingInterval);
  }
};
