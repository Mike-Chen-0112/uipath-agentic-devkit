const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const cliRoot = process.argv[2];
const dist = path.join(cliRoot, 'dist');
const rendererPath = fs.readdirSync(dist).map(name => path.join(dist, name))
  .find(name => name.endsWith('.js') && fs.readFileSync(name, 'utf8').includes('function createHelpConfiguration('));
const source = fs.readFileSync(rendererPath, 'utf8');
const renderer = source.slice(source.indexOf('var OUTPUT_FLAG ='), source.indexOf('// src/utils/parseError.ts'));
const raw = {};
for (const command of ['', 'snapshot']) {
  for (const format of ['json', 'table', 'plain']) {
    const args = ['rpa', 'uia', ...(command ? [command] : []), '--help', '--output', format];
    const result = spawnSync(process.execPath, [path.join(dist, 'index.js'), ...args], { encoding: 'utf8' });
    raw[`${command || 'parent'}-${format}`] = { command: `uip ${args.join(' ')}`, exitCode: result.status, output: result.stdout, error: result.stderr };
  }
}
const base = JSON.parse(raw['parent-json'].output).Data;
const derived = {};
for (const command of ['', 'snapshot']) {
  const data = JSON.parse(JSON.stringify(base));
  data.Command = command || 'uia';
  data.Usage = `uip rpa uia${command ? ' snapshot' : ''} [options]`;
  data.Subcommands = command ? [] : [{ Name: 'snapshot', Description: 'Synthetic discovery input, not installed UIA capability' }];
  for (const format of ['json', 'table']) {
    const root = { name: () => 'uip', parent: null };
    const rpa = { name: () => 'rpa', parent: root };
    const uia = { name: () => 'uia', parent: rpa };
    const cmd = command ? { name: () => command, parent: uia } : uia;
    const helper = {
      commandUsage: () => data.Usage, commandDescription: () => data.Description,
      visibleCommands: () => data.Subcommands.map(entry => ({ name: () => entry.Name, aliases: () => [], description: entry.Description })),
      subcommandDescription: sub => sub.description
    };
    const context = {
      OUTPUT_FORMATS: ['table','json','yaml','plain','markdown'], RESULTS: { Success: 'Success' },
      getOutputFormat: () => format, getHelpRequested: () => false, getOutputFormatExplicit: () => true,
      getOutputSink: () => ({ capabilities: { outputWidth: 100, isInteractive: false } }),
      extractCommandHelp: () => data, OutputFormatter: { formatToString: envelope => JSON.stringify(envelope, null, 2) },
      cmd, helper
    };
    vm.createContext(context);
    derived[`${command || 'parent'}-${format}`] = vm.runInContext(renderer + '\ncreateHelpConfiguration(false).formatHelp(cmd, helper)', context);
  }
}
fs.writeFileSync(path.join(__dirname, 'captures.json'), JSON.stringify({
  provenance: {
    cliVersion: JSON.parse(fs.readFileSync(path.join(cliRoot, 'package.json'), 'utf8')).version,
    rendererFile: path.basename(rendererPath), rendererSha256: crypto.createHash('sha256').update(source).digest('hex'),
    raw: 'Unmodified command stdout/stderr; central repository has no discovery project.',
    derived: 'Official installed table renderer and structured-help assembly with synthetic parent/child model inputs. JSON serialization uses JSON.stringify. NOT raw child discovery or installed capability proof.',
    plain: 'Official --output plain is flattened and unsupported; table is the supported boxed text renderer.'
  }, raw, derived
}, null, 2) + '\n');