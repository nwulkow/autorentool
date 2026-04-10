const { createApp } = require('vue');
const fs = require('fs');
const jsdom = require('jsdom');
const { JSDOM } = jsdom;
const dom = new JSDOM(`<!DOCTYPE html><div id="app"></div>`);
global.window = dom.window;
global.document = dom.window.document;

function uid(){ return "x"; }

// Extract the component options from app.js
let appJs = fs.readFileSync('app.js', 'utf8');
let compSource = appJs.split('const AutorinoApp = ')[1].split('Vue.createApp(AutorinoApp)')[0];
// Evaluate
// const AutorinoApp = { ... }
let autorinoApp = eval(`(${compSource})`);

console.log("Found");
