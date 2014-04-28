/** @jsx React.DOM */

var debug = function (msg) {
    var el = document.getElementById ('log');
    el.innerHTML = '[' + (new Date ()).toString () + ']: ' + msg + '<br />' + el.innerHTML;
};
RPC.init ('ws://'+document.location.host+'/ws');

var ClusterStatus = React.createClass ({

  getInitialState: function () {
    return {clusterInfo: {}};
  },

  tick: function () {
    this.updateClusterInfo ();
  },

  updateClusterInfo: function () {
    var infoCbk = function (response) {
      this.setState ({clusterInfo: response.result});
    }.bind (this);
    RPC.call ('DWS.Example', 'get_mnesia_info', null, infoCbk);
  },

  componentWillMount: function () {
    this.updateClusterInfo ();
  },

  componentDidMount: function () {
    this.interval = setInterval (this.tick, 1000);
  },

  componentWillUnmount: function () {
    clearInterval (this.interval);
  },

  render: function () {
    var ci = this.state.clusterInfo;
    return (<table>
            {Object.keys (ci).map (function (key) {
                var val = ci [key];
                return (<tr key={key}><td>{key}</td><td><code>{val}</code></td></tr>);
            })}
            </table>);
  }
});

var SessionListing = React.createClass ({

  getInitialState: function () {
    return {sessions: []};
  },

  tick: function () {
    this.updateSessions ();
  },

  updateSessions: function () {
    var sessionCbk = function (response) {
      this.setState ({sessions: response.result});
    }.bind (this);
    RPC.call ('DWS.Example', 'reveal_session_data', null, sessionCbk);
  },

  componentWillMount: function () {
    this.updateSessions ();
  },

  componentDidMount: function () {
    this.interval = setInterval (this.tick, 1000);
  },

  componentWillUnmount: function () {
    clearInterval (this.interval);
  },

  render: function () {
    var sessions = this.state.sessions || [];
    return (<table>
            <tr><th>SessionID</th><th>Created</th><th>State</th></tr>
            {sessions.map (function (s, key) {
                return (<tr key={key}><td>{s.id}</td><td>{s.created}</td><td><code>{s.state}</code></td></tr>);
            })}
            </table>);
  }
});

React.renderComponent(<div>
                        <ClusterStatus />
                        <br />
                        <SessionListing />
                      </div>,
                      document.getElementById ('main'));

