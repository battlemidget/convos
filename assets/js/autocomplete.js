import {emojis, md} from './md';
import {regexpEscape} from './util';

export const commands = [];
export const maxNumMatches = 20;

export default function autocomplete(category, params) {
  return autocomplete[category] ? autocomplete[category](params) : [];
}

autocomplete.commands = ({query}) => {
  const opts = [];

  for (let i = 0; i < commands.length; i++) {
    if (commands[i].cmd.indexOf(query) != 0) continue;
    const val = commands[i].alias || commands[i].cmd;
    const text = commands[i].example.replace(/</g, '&lt;');
    opts.push({text, val});
  }

  return opts;
};

autocomplete.dialogs = ({dialog, query, user}) => {
  const dialogs = user.findDialog({connection_id: dialog.connection_id}).dialogs.toArray();
  const opts = [];

  for (let i = 0; i < dialogs.length; i++) {
    if (dialogs[i].name.toLowerCase().indexOf(query) == -1) continue;
    opts.push({text: dialogs[i].name, val: dialogs[i].dialog_id});
    if (opts.length >= maxNumMatches) break;
  }

  return opts;
};

autocomplete.emojis = ({query}) => {
  const opts = [];

  [':', '_'].map(p => p + query.slice(1, 2)).forEach(group => {
    const emojiList = emojis(group, 'group');
    for (let i = 0; i < emojiList.length; i++) {
      if (emojiList[i].shortname.indexOf(query) >= 0) opts.push({val: emojiList[i].emoji, text: md(emojiList[i].emoji)});
      if (opts.length >= maxNumMatches) break;
    }
  });

  return opts;
};

autocomplete.nicks = ({dialog, query}) => {
  const participants = dialog.participants();
  const re = new RegExp('^' + regexpEscape(query.slice(1)), 'i');
  const opts = [];

  for (let p of participants) {
    if (opts.length >= maxNumMatches) break;
    if (p.nick.match(re)) opts.push({val: p.nick});
  }

  return opts;
};

commands.push({cmd: '/me', example: '/me <msg>', description: 'Send message as an action.'});
commands.push({cmd: '/say', example: '/say <msg>', description: 'Used when you want to send a message starting with '/'.'});
commands.push({cmd: '/topic', example: '/topic or /topic <new topic>', description: 'Show current topic, or set a new one.'});
commands.push({cmd: '/whois', example: '/whois <nick>', description: 'Show information about a user.'});
commands.push({cmd: '/query', example: '/query <nick>', description: 'Open up a new chat window with nick.'});
commands.push({cmd: '/msg', example: '/msg <nick> <msg>', description: 'Send a direct message to nick.'});
commands.push({cmd: '/names', example: '/names', description: 'Show participants in the channel.'});
commands.push({cmd: '/join', example: '/join <#channel>', description: 'Join channel and open up a chat window.'});
commands.push({cmd: '/nick', example: '/nick <nick>', description: 'Change your wanted nick.'});
commands.push({cmd: '/part', example: '/part', description: 'Leave channel, and close window.'});
commands.push({cmd: '/close', example: '/close <nick>', description: 'Close conversation with nick, defaults to current active.'});
commands.push({cmd: '/kick', example: '/kick <nick>', description: 'Kick a user from the current channel.'});
commands.push({cmd: '/mode', example: '/mode +o #channel nick', description: 'Change mode of yourself or a user'});
commands.push({cmd: '/reconnect', example: '/reconnect', description: 'Restart the current connection.'});
commands.push({cmd: '/cs', example: '/cs <msg>', description: 'Short for "/msg chanserv ...".', alias: '/msg chanserv'});
commands.push({cmd: '/ns', example: '/ns <msg>', description: 'Short for "/msg nickserv ...".', alias: '/msg nickserv'});
commands.push({cmd: '/hs', example: '/hs <msg>', description: 'Short for "/msg hostserv ...".', alias: '/msg hostserv'});
commands.push({cmd: '/bs', example: '/bs <msg>', description: 'Short for "/msg botserv ...".', alias: '/msg botserv'});
