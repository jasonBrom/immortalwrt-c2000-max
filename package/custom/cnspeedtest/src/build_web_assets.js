'use strict';

const fs = require('fs');
const path = require('path');

const root = __dirname;
const Babel = require(path.join(root, 'web_assets', 'vendor', 'babel.min.js'));
const input = path.join(root, 'web_assets', 'app.jsx');
const output = path.join(root, 'web_assets', 'app.js');
const source = fs.readFileSync(input, 'utf8');
const result = Babel.transform(source, {
  presets: [ 'react' ],
  comments: false,
  compact: false,
  sourceMaps: false
});

fs.writeFileSync(output, result.code + '\n', 'utf8');
console.log('Generated ' + path.relative(root, output));
