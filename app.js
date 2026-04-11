const { createApp } = Vue;

/* ═══════════════════════════════════════════════════════════════════
   Constants
   ═══════════════════════════════════════════════════════════════════ */
const CHAR_PALETTE = [
  '#e74c3c','#3498db','#2ecc71','#f39c12','#9b59b6',
  '#1abc9c','#e67e22','#e84393','#00b894','#6c5ce7',
  '#fd79a8','#00cec9','#d63031','#0984e3','#6ab04c',
];
const AREA_DEFAULTS = {
  lake:   { color:'rgba(52,152,219,0.45)', stroke:'#2980b9', strokeWidth:2 },
  road:   { color:'#95a5a6',               stroke:'#95a5a6', strokeWidth:14 },
  sand:   { color:'rgba(241,196,15,0.40)', stroke:'#f1c40f', strokeWidth:2 },
  garden: { color:'rgba(46,204,113,0.40)', stroke:'#27ae60', strokeWidth:2 },
};
const ICON_DEFAULTS = {
  tree:'#27ae60', house:'#e74c3c', castle:'#7f8c8d', car:'#3498db',
  bed:'#9b59b6', table:'#8B4513', door:'#d35400',
  shop:'#e67e22', building:'#34495e', fountain:'#1abc9c',
};
const ALL_ICONS = Object.keys(ICON_DEFAULTS);
const ALL_AREAS = Object.keys(AREA_DEFAULTS);
const POST_IT_COLORS = [
  {value:'#fff9c4',label:'Yellow'},{value:'#f8bbd0',label:'Pink'},
  {value:'#bbdefb',label:'Blue'},{value:'#c8e6c9',label:'Green'},
  {value:'#ffe0b2',label:'Orange'},{value:'#e1bee7',label:'Purple'},
  {value:'#b2dfdb',label:'Teal'},{value:'#ffccbc',label:'Peach'},
];

/* ═══════════════════════════════════════════════════════════════════
   Helpers
   ═══════════════════════════════════════════════════════════════════ */
function uid(){ return crypto.randomUUID(); }
function clamp(v,lo,hi){ return Math.max(lo,Math.min(hi,v)); }
function niceInterval(range){
  if(range<=0) return 1;
  const rough=range/8, mag=Math.pow(10,Math.floor(Math.log10(rough))), r=rough/mag;
  if(r<=1.5) return mag; if(r<=3.5) return 2*mag; if(r<=7.5) return 5*mag; return 10*mag;
}

/* ═══════════════════════════════════════════════════════════════════
   Serialization
   ═══════════════════════════════════════════════════════════════════ */
function serializeBook(state){
  const b=state.book;
  return {
    title:b.title, author:b.author, chapters:b.chapters, tags:b.tags||[],
    characters:b.characters.map(c=>({id:c.id,name:c.name,description:c.description,tags:c.tags||[]})),
    character_relations:b.character_relations.map(r=>({
      id:r.id, character1_id:r.character1Id, character2_id:r.character2Id, relation_type:r.relationType
    })),
    canvas_nodes:state.canvasNodes.map(n=>({character_id:n.characterId,x:n.x,y:n.y})),
    questions:b.questions.map(q=>({id:q.id,text:q.text,answer:q.answer,answered:q.answered})),
    event_orders:state.eventOrders.map(o=>({
      id:o.id, name:o.name, timeline_config:o.timelineConfig,
      character_columns:o.characterColumns.map(col=>({
        character_id:col.characterId,
        events:col.events.map(e=>({id:e.id,description:e.description,y_pos:e.yPos,height:e.height,time:e.time,location_id:e.locationId||null}))
      })),
    })),
    locations:b.locations.map(loc=>({
      id:loc.id,name:loc.name,description:loc.description,
      width:loc.width,height:loc.height,unit:loc.unit,objects:loc.objects
    })),
    topics:(b.topics||[]).map(t=>({id:t.id,name:t.name,notes:t.notes,url_links:t.urlLinks})),
  };
}

function deserializeBook(data){
  const book={
    title:data.title, author:data.author, chapters:data.chapters||[],
    tags:data.tags||[],
    characters:(data.characters||[]).map(c=>({id:c.id||uid(),name:c.name,description:c.description,tags:c.tags||[]})),
    character_relations:(data.character_relations||[]).map(r=>({
      id:r.id||uid(), character1Id:r.character1_id, character2Id:r.character2_id, relationType:r.relation_type
    })),
    questions:(data.questions||[]).map(q=>({id:q.id||uid(),text:q.text,answer:q.answer||'',answered:!!q.answered})),
    locations:(data.locations||[]).map(loc=>({
      id:loc.id||uid(),name:loc.name,description:loc.description||'',
      width:loc.width||10,height:loc.height||10,unit:loc.unit||'m',objects:loc.objects||[]
    })),
    topics:(data.topics||[]).map(t=>({
      id:t.id||uid(),name:t.name,
      notes:(t.notes||[]).map(n=>typeof n==='string'?{id:uid(),text:n,color:'#fff9c4'}:({...n,id:n.id||uid()})),
      urlLinks:t.url_links||t.urlLinks||[],
    })),
  };
  const canvasNodes=(data.canvas_nodes||[]).map(n=>({characterId:n.character_id,x:n.x,y:n.y}));
  const eventOrders=(data.event_orders||[]).map(o=>{
    const tc=o.timeline_config||{mode:'custom',pixels_per_marker:80,custom_labels:['Start','Middle','End']};
    return {
      id:o.id||uid(), name:o.name||'Event Order', timelineConfig:tc,
      characterColumns:(o.character_columns||[]).map(col=>({
        characterId:col.character_id,
        events:(col.events||[]).map(e=>({
          id:e.id||uid(),description:e.description||'',yPos:e.y_pos||0,height:e.height||50,time:e.time||'',locationId:e.location_id||null
        }))
      })),
    };
  });
  return {book,canvasNodes,eventOrders};
}

/* ═══════════════════════════════════════════════════════════════════
   Timeline marker generation
   ═══════════════════════════════════════════════════════════════════ */
function generateMarkers(cfg){
  if(!cfg) return [{label:'Start',index:0}];
  switch(cfg.mode){
    case 'clock': return genClockMarkers(cfg);
    case 'weekday': return ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'].map((l,i)=>({label:l,index:i}));
    case 'week': {
      const s=cfg.week_start||1, e=cfg.week_end||8;
      return Array.from({length:e-s+1},(_,i)=>({label:'Week '+(s+i),index:i}));
    }
    case 'month': return ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'].map((l,i)=>({label:l,index:i}));
    case 'date': return genDateMarkers(cfg);
    default: return (cfg.custom_labels||['Start','Middle','End']).map((l,i)=>({label:l,index:i}));
  }
}
function genClockMarkers(cfg){
  const [sh,sm]=(cfg.clock_start||'08:00').split(':').map(Number);
  const [eh,em]=(cfg.clock_end||'20:00').split(':').map(Number);
  const interval=cfg.clock_interval_min||60; const marks=[];
  for(let m=sh*60+sm;m<=eh*60+em;m+=interval){
    const h=Math.floor(m/60),mn=m%60;
    marks.push({label:String(h).padStart(2,'0')+':'+String(mn).padStart(2,'0'),index:marks.length,totalMin:m});
  }
  return marks;
}
function genDateMarkers(cfg){
  const marks=[]; let cur=new Date(cfg.date_start||'2026-01-01');
  const end=new Date(cfg.date_end||'2026-01-31'); const step=cfg.date_interval_days||1;
  while(cur<=end){marks.push({label:cur.toLocaleDateString('en-US',{month:'short',day:'numeric'}),index:marks.length});cur.setDate(cur.getDate()+step);}
  return marks;
}
function timeFromY(yPos,markers,cfg){
  if(!markers.length) return '';
  const gs=cfg.gap_sizes;
  if(gs&&gs.length){
    let cumY=0;
    for(let i=0;i<markers.length;i++){
      const gapH=gs[i]||(cfg.pixels_per_marker||80);
      if(yPos<=cumY+gapH||i===markers.length-1){
        const frac=gapH>0?(yPos-cumY)/gapH:0;
        if(i+1<markers.length){
          if(cfg.mode==='clock'&&markers[0].totalMin!==undefined){
            const m=Math.round(markers[i].totalMin+frac*(markers[i+1].totalMin-markers[i].totalMin));
            return String(Math.floor(m/60)).padStart(2,'0')+':'+String(m%60).padStart(2,'0');
          }
          return frac<0.5?markers[i].label:markers[i+1].label;
        }
        return markers[i].label;
      }
      cumY+=gapH;
    }
    return markers[markers.length-1].label;
  }
  const ppm=cfg.pixels_per_marker||80;
  if(!markers.length) return '';
  const idx=yPos/ppm;
  if(cfg.mode==='clock'&&markers[0].totalMin!==undefined){
    const lo=Math.floor(idx),hi=Math.ceil(idx),frac=idx-lo;
    if(lo>=markers.length) return markers[markers.length-1].label;
    if(hi>=markers.length||lo===hi) return markers[lo].label;
    const m=Math.round(markers[lo].totalMin+frac*(markers[hi].totalMin-markers[lo].totalMin));
    return String(Math.floor(m/60)).padStart(2,'0')+':'+String(m%60).padStart(2,'0');
  }
  const near=clamp(Math.round(idx),0,markers.length-1);
  return markers[near].label;
}

/* ═══════════════════════════════════════════════════════════════════
   i18n
   ═══════════════════════════════════════════════════════════════════ */
const I18N={de:{
  'Loading…':'Laden…','Your Books':'Deine Bücher','by':'von','chars':'Charaktere',
  'questions':'Fragen','locations':'Orte','Or create a new book':'Oder erstelle ein neues Buch',
  'Create your first book':'Erstelle dein erstes Buch','Title':'Titel','Author':'Autor',
  'Create Book':'Buch erstellen','Characters':'Charaktere','Locations':'Orte',
  'Event orders':'Ereignisfolgen','Questions':'Fragen','Notes':'Notizen',
  '← All Books':'← Alle Bücher','● Unsaved changes':'● Ungespeicherte Änderungen',
  '+ Add Character':'+ Charakter hinzufügen','💾 Save':'💾 Speichern',
  'New Character':'Neuer Charakter','Name':'Name','Description':'Beschreibung',
  'Add':'Hinzufügen','Cancel':'Abbrechen','Tags':'Tags',
  'No characters yet.':'Noch keine Charaktere.','Character Relationship Map':'Beziehungskarte',
  '＋ Wider':'＋ Breiter','Reset width':'Breite zurücksetzen','＋ Taller':'＋ Höher','Reset height':'Höhe zurücksetzen',
  '🔗 Add Link':'🔗 Verbindung',
  'Click two characters on the map to link them.':'Klicke zwei Charaktere auf der Karte, um sie zu verbinden.',
  'Drag onto map ↓':'Auf Karte ziehen ↓','🗺️ Drop characters here':'🗺️ Charaktere hierher ziehen',
  'Relations':'Beziehungen','Event Orders':'Ereignisfolgen','Open':'Öffnen','columns':'Spalten',
  '+ New Event Order':'+ Neue Ereignisfolge','⚙ Timeline':'⚙ Zeitleiste',
  'Timeline Configuration':'Zeitleisten-Konfiguration','Mode':'Modus',
  'Custom Labels':'Eigene Bezeichnungen','Clock (hours)':'Uhr (Stunden)',
  'Days of Week':'Wochentage','Weeks':'Wochen','Months':'Monate','Dates':'Daten',
  'Pixels per marker':'Pixel pro Markierung','Start':'Start','End':'Ende',
  'Interval (min)':'Intervall (Min)','Start week':'Startwoche','End week':'Endwoche',
  'Start date':'Startdatum','End date':'Enddatum','Interval (days)':'Intervall (Tage)',
  'Labels (top → bottom)':'Bezeichnungen (oben → unten)','+ Insert here':'+ Hier einfügen',
  'Drag characters here to add columns →':'Charaktere hierher ziehen →',
  '+ General':'+ Allgemein','General':'Allgemein','Filter by tags:':'Nach Tags filtern:',
  '+ Add matching characters':'+ Passende Charaktere hinzufügen','✕ Clear':'✕ Löschen',
  '(double-click to edit)':'(Doppelklick zum Bearbeiten)','📍 No location':'📍 Kein Ort',
  '+ Add':'+ Hinzufügen','Answered':'Beantwortet','No questions yet.':'Noch keine Fragen.',
  '+ Add Location':'+ Ort hinzufügen','New Location':'Neuer Ort','Width':'Breite','Height':'Höhe',
  'Unit':'Einheit','Create':'Erstellen','← Back':'← Zurück','objects':'Objekte',
  'No locations yet.':'Noch keine Orte.','Properties':'Eigenschaften','Fill Color':'Füllfarbe',
  'Stroke':'Kontur','Stroke Width':'Konturbreite','Scale':'Maßstab',
  'Delete Object':'Objekt löschen','Topics':'Themen','Links':'Links',
  '+ Add Note':'+ Notiz hinzufügen','Create Relation':'Beziehung erstellen',
  'Relation type':'Beziehungsart','Create Link':'Verbindung erstellen',
  'Unsaved Changes':'Ungespeicherte Änderungen',
  'You have unsaved changes. What would you like to do?':'Du hast ungespeicherte Änderungen. Was möchtest du tun?',
  'Save & Continue':'Speichern & Fortfahren','Discard':'Verwerfen',
  'Import Characters':'Charaktere importieren','Import Locations':'Orte importieren',
  'Select a book:':'Buch auswählen:','Import':'Importieren',
  'No other books available.':'Keine anderen Bücher verfügbar.',
  'No characters in this book.':'Keine Charaktere in diesem Buch.',
  'No locations in this book.':'Keine Orte in diesem Buch.',
  'Book saved ✓':'Buch gespeichert ✓','Save failed!':'Speichern fehlgeschlagen!',
  'Book renamed ✓':'Buch umbenannt ✓','Rename failed!':'Umbenennung fehlgeschlagen!',
  'Characters imported ✓':'Charaktere importiert ✓','Locations imported ✓':'Orte importiert ✓',
  'e.g. The Great Adventure':'z.B. Das große Abenteuer','e.g. Jane Doe':'z.B. Max Mustermann',
  'Add tag…':'Tag hinzufügen…','Type a question…':'Frage eingeben…',
  'Type your answer…':'Antwort eingeben…','Castle Grounds':'Burggelände',
  'Optional description':'Optionale Beschreibung','e.g. friends, rivals':'z.B. Freunde, Rivalen',
  'Describe event…':'Ereignis beschreiben…','New topic…':'Neues Thema…',
  'Write a note…':'Notiz schreiben…',
  'Select or create a topic to start adding notes.':'Wähle oder erstelle ein Thema, um Notizen hinzuzufügen.',
  'Tip: Ctrl + scroll wheel on the timeline to zoom in/out.':'Tipp: Strg + Scrollrad auf der Zeitleiste zum Zoomen.',
  'Drag characters from above or add a General column, then double-click to place events.':'Ziehe Charaktere von oben oder füge eine Allgemein-Spalte hinzu, dann doppelklicke um Ereignisse zu platzieren.',
  'Click to rename':'Klicken zum Umbenennen',
  'Remember to save your changes!':'Denke daran, deine Änderungen zu speichern!',
  'Unknown':'Unbekannt','Delete character':'Charakter löschen','Delete':'Löschen',
  'Delete event order':'Ereignisfolge löschen','Delete topic':'Thema löschen',
  'Delete note':'Notiz löschen','Remove column':'Spalte entfernen',
  'select':'Auswahl','rectangle':'Rechteck','ellipse':'Ellipse','circle':'Kreis',
  'tree':'Baum','house':'Haus','castle':'Burg','car':'Auto','bed':'Bett',
  'table':'Tisch','door':'Tür','shop':'Laden','building':'Gebäude','fountain':'Brunnen',
  'lake':'See','road':'Straße','sand':'Sand','garden':'Garten',
  'Increase gap':'Abstand vergrößern','Decrease gap':'Abstand verkleinern',
  'Yellow':'Gelb','Pink':'Rosa','Blue':'Blau','Green':'Grün','Orange':'Orange',
  'Purple':'Lila','Teal':'Türkis','Peach':'Pfirsich',
  'Source book':'Quellbuch','Select a book…':'Buch auswählen…',
  'No items to import.':'Keine Elemente zum Importieren.',
  'Save':'Speichern','Back':'Zurück','Add Location':'Ort hinzufügen',
  'Add matching characters':'Passende Charaktere hinzufügen','Clear':'Löschen',
  'Clear tag filter':'Tag-Filter löschen','No location':'Kein Ort',
  'Add Note':'Notiz hinzufügen',
  '📥 Import Characters':'📥 Charaktere importieren','📥 Import Locations':'📥 Orte importieren',
}};

/* ═══════════════════════════════════════════════════════════════════
   Vue App
   ═══════════════════════════════════════════════════════════════════ */
createApp({
  data(){return{
    loading:true, dirty:false, savedBooks:[], book:null,
    editingTitle:false, titleDraft:'', locale:'en',
    setup:{title:'',author:''},
    activeTab:'Characters',
    tabs:['Characters','Locations','Event orders','Questions','Notes'],
    importModal:{open:false,type:'characters',bookTitle:'',selectedIds:[]},
    colDragIdx:null,
    // unsaved dialog
    showUnsavedDialog:false, pendingAction:null,
    // characters
    newChar:{open:false,name:'',description:''},
    tagInputs:{}, tagDropdownCharId:null,
    // canvas
    canvasNodes:[], linkMode:false, linkSourceId:null, canvasPaneWidth:0, canvasWrapHeight:0, selectedNodeIds:[],
    linkModal:{open:false,c1:null,c2:null,type:''},
    // event orders
    eventOrders:[], currentOrderId:null, tlConfigOpen:false, editingEvtId:null, eoSelectedTags:[],
    // questions
    newQText:'',
    // locations
    newLoc:{open:false,name:'',description:'',width:10,height:10,unit:'m'},
    currentLocId:null,
    drawTool:'select', selectedObjId:null,
    drawingPts:[], isDrawingShape:false, drawStart:null, cursorPos:{x:0,y:0},
    // notes
    currentTopicId:null, newTopicName:'', newNoteText:'', newUrl:'',
    postitColors:POST_IT_COLORS,
    // toast
    toast:'',
    // constants exposed to template
    ALL_ICONS,
  }},
  computed:{
    currentOrder(){ return this.eventOrders.find(o=>o.id===this.currentOrderId)||null; },
    currentMarkers(){ return this.currentOrder?generateMarkers(this.currentOrder.timelineConfig):[]; },
    totalTlHeight(){
      if(!this.currentOrder) return 0;
      const cfg=this.currentOrder.timelineConfig,gs=cfg.gap_sizes;
      if(gs&&gs.length) return gs.reduce((a,b)=>a+b,0);
      return this.currentMarkers.length*((cfg.pixels_per_marker)||80);
    },
    tlColStyle(){
      if(!this.currentOrder) return {};
      const n=this.filteredOrderColumns.length;
      if(n===0) return {};
      const w=n===1?'100%':n===2?'50%':Math.max(220,Math.floor(600/n))+'px';
      return {width:w,minWidth:'220px',flexShrink:n<=2?'1':'0'};
    },
    allTags(){
      if(!this.book) return [];
      const s=new Set(this.book.tags||[]);
      this.book.characters.forEach(c=>(c.tags||[]).forEach(t=>s.add(t)));
      return [...s].sort();
    },
    filteredOrderColumns(){
      if(!this.currentOrder) return [];
      if(!this.eoSelectedTags.length) return this.currentOrder.characterColumns;
      return this.currentOrder.characterColumns.filter(col=>{
        if(!col.characterId) return true; // General column always shown
        const ch=this.book.characters.find(c=>c.id===col.characterId);
        if(!ch) return false;
        return this.eoSelectedTags.every(tag=>(ch.tags||[]).includes(tag));
      });
    },
    currentLoc(){ return this.book?.locations.find(l=>l.id===this.currentLocId)||null; },
    selectedObj(){
      if(!this.currentLoc||!this.selectedObjId) return null;
      return this.currentLoc.objects.find(o=>o.id===this.selectedObjId)||null;
    },
    computedLinks(){
      if(!this.book) return [];
      return this.book.character_relations.map(rel=>{
        const n1=this.canvasNodes.find(n=>n.characterId===rel.character1Id);
        const n2=this.canvasNodes.find(n=>n.characterId===rel.character2Id);
        if(!n1||!n2) return null;
        return {id:rel.id,x1:n1.x+66,y1:n1.y+18,x2:n2.x+66,y2:n2.y+18,label:rel.relationType};
      }).filter(Boolean);
    },
    currentTopic(){
      if(!this.book||!this.currentTopicId) return null;
      return this.book.topics.find(t=>t.id===this.currentTopicId)||null;
    },
    importableItems(){
      if(!this.importModal.open||!this.importModal.bookTitle) return [];
      const src=this.savedBooks.find(b=>b.title===this.importModal.bookTitle);
      if(!src) return [];
      return this.importModal.type==='characters'?(src.characters||[]):(src.locations||[]);
    },
    locXTicks(){
      if(!this.currentLoc) return [];
      const loc=this.currentLoc, cw=this.locCanvasW(), iv=niceInterval(loc.width), sc=cw/loc.width, ticks=[];
      for(let v=0;v<=loc.width;v+=iv) ticks.push({value:v,px:v*sc,label:v});
      return ticks;
    },
    locYTicks(){
      if(!this.currentLoc) return [];
      const loc=this.currentLoc, ch=this.locCanvasH(), iv=niceInterval(loc.height), sc=ch/loc.height, ticks=[];
      for(let v=0;v<=loc.height;v+=iv) ticks.push({value:v,px:v*sc,label:v});
      return ticks;
    },
  },
  async mounted(){
    this._beforeUnload=e=>{if(this.dirty){e.preventDefault();e.returnValue='';}};
    window.addEventListener('beforeunload',this._beforeUnload);
    window.addEventListener('keydown',this.onKey);
    await this.fetchBooks(); this.loading=false;
  },
  beforeUnmount(){
    window.removeEventListener('beforeunload',this._beforeUnload);
    window.removeEventListener('keydown',this.onKey);
  },
  updated(){
    const el=this.$refs.tlScroll;
    if(el&&!el._wlAttached){
      el.addEventListener('wheel',this.onTlWheel,{passive:false});
      el._wlAttached=true;
    }
  },
  methods:{
    mark(){ this.dirty=true; },
    t(key){ return this.locale==='en'?key:(I18N[this.locale]&&I18N[this.locale][key])||key; },
    /* ── timeline gap helpers ─────────── */
    markerY(idx){
      if(!this.currentOrder) return 0;
      const cfg=this.currentOrder.timelineConfig,gs=cfg.gap_sizes;
      if(!gs) return idx*(cfg.pixels_per_marker||80);
      let y=0;for(let i=0;i<idx&&i<gs.length;i++) y+=gs[i]; return y;
    },
    ensureGapSizes(){
      if(!this.currentOrder) return;
      const cfg=this.currentOrder.timelineConfig,n=this.currentMarkers.length;
      if(!cfg.gap_sizes||cfg.gap_sizes.length!==n) cfg.gap_sizes=Array(n).fill(cfg.pixels_per_marker||80);
    },
    growGap(idx){
      this.ensureGapSizes();
      const cfg=this.currentOrder.timelineConfig;
      let cutY=0;for(let i=0;i<=idx;i++) cutY+=cfg.gap_sizes[i];
      cfg.gap_sizes[idx]+=20;
      this.currentOrder.characterColumns.forEach(col=>{col.events.forEach(evt=>{if(evt.yPos>=cutY) evt.yPos+=20;});});
      this.mark();
    },
    shrinkGap(idx){
      this.ensureGapSizes();
      const cfg=this.currentOrder.timelineConfig;
      if(cfg.gap_sizes[idx]<=30) return;
      let cutY=0;for(let i=0;i<=idx;i++) cutY+=cfg.gap_sizes[i];
      cfg.gap_sizes[idx]=Math.max(30,cfg.gap_sizes[idx]-20);
      this.currentOrder.characterColumns.forEach(col=>{col.events.forEach(evt=>{if(evt.yPos>=cutY) evt.yPos=Math.max(0,evt.yPos-20);});});
      this.mark();
    },
    /* ── import ───────────────────────── */
    async openImportModal(type){
      await this.fetchBooks();
      this.importModal={open:true,type,bookTitle:'',selectedIds:[]};
    },
    toggleImportItem(id){
      const idx=this.importModal.selectedIds.indexOf(id);
      if(idx===-1) this.importModal.selectedIds.push(id);
      else this.importModal.selectedIds.splice(idx,1);
    },
    confirmImport(){
      const m=this.importModal;
      if(!m.bookTitle||!m.selectedIds.length) return;
      const src=this.savedBooks.find(b=>b.title===m.bookTitle);if(!src) return;
      if(m.type==='characters'){
        (src.characters||[]).filter(c=>m.selectedIds.includes(c.id)).forEach(c=>{
          this.book.characters.push({id:uid(),name:c.name,description:c.description,tags:[...(c.tags||[])]});
        });
      } else {
        (src.locations||[]).filter(l=>m.selectedIds.includes(l.id)).forEach(l=>{
          this.book.locations.push({id:uid(),name:l.name,description:l.description||'',
            width:l.width||10,height:l.height||10,unit:l.unit||'m',objects:JSON.parse(JSON.stringify(l.objects||[]))});
        });
      }
      this.importModal.open=false;this.mark();
      this.showToast(this.t(m.type==='characters'?'Characters imported ✓':'Locations imported ✓'));
    },
    growCanvasPane(){
      const pane=this.$refs.canvasPane;
      const current=this.canvasPaneWidth||( pane ? pane.offsetWidth : 600);
      this.canvasPaneWidth=current+200;
    },
    resetCanvasPane(){ this.canvasPaneWidth=0; },
    growCanvasWrap(){
      const wrap=this.$refs.canvasWrap;
      const current=this.canvasWrapHeight||(wrap ? wrap.offsetHeight : 440);
      this.canvasWrapHeight=current+150;
    },
    resetCanvasWrap(){ this.canvasWrapHeight=0; },
    /* ── palette ──────────────────────── */
    charColor(id){
      if(!id) return '#888888';
      if(!this.book) return '#999';
      const i=this.book.characters.findIndex(c=>c.id===id);
      return CHAR_PALETTE[i%CHAR_PALETTE.length];
    },
    charColorLight(id){
      if(!id) return 'rgba(136,136,136,0.12)';
      const c=this.charColor(id);
      const r=parseInt(c.slice(1,3),16),g=parseInt(c.slice(3,5),16),b=parseInt(c.slice(5,7),16);
      return 'rgba('+r+','+g+','+b+',0.12)';
    },
    /* ── API ──────────────────────────── */
    async fetchBooks(){
      try{const r=await fetch('/api/books');this.savedBooks=await r.json();}
      catch(e){console.error(e);this.savedBooks=[];}
    },
    async saveBook(){
      if(!this.book) return;
      try{
        const r=await fetch('/api/books/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(serializeBook(this))});
        if(r.ok){this.dirty=false;this.showToast(this.t('Book saved ✓'));}
        else this.showToast(this.t('Save failed!'));
      }catch(e){console.error(e);this.showToast(this.t('Save failed!'));}
    },
    /* ── title rename ─────────────────── */
    startEditTitle(){
      this.titleDraft=this.book.title;
      this.editingTitle=true;
      this.$nextTick(()=>{ const el=this.$refs.titleInput; if(el){el.focus();el.select();} });
    },
    async commitTitleEdit(){
      const newTitle=this.titleDraft.trim();
      this.editingTitle=false;
      if(!newTitle||newTitle===this.book.title) return;
      const oldTitle=this.book.title;
      this.book.title=newTitle;
      try{
        const r=await fetch('/api/books/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(serializeBook(this))});
        if(r.ok){
          this.dirty=false;
          await fetch('/api/books/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({title:oldTitle})});
          this.showToast(this.t('Book renamed ✓'));
        } else {
          this.book.title=oldTitle;
          this.showToast(this.t('Rename failed!'));
        }
      }catch(e){console.error(e);this.book.title=oldTitle;this.showToast(this.t('Rename failed!'));}
    },
    cancelTitleEdit(){
      this.editingTitle=false;
    },
    showToast(m){this.toast=m;setTimeout(()=>{this.toast='';},2200);},
    /* ── unsaved guard ───────────────── */
    guardAction(action){
      if(this.dirty){this.pendingAction=action;this.showUnsavedDialog=true;}
      else action();
    },
    async unsavedSave(){await this.saveBook();this.showUnsavedDialog=false;if(this.pendingAction)this.pendingAction();this.pendingAction=null;},
    unsavedDiscard(){this.dirty=false;this.showUnsavedDialog=false;if(this.pendingAction)this.pendingAction();this.pendingAction=null;},
    unsavedCancel(){this.showUnsavedDialog=false;this.pendingAction=null;},
    /* ── book management ─────────────── */
    createBook(){
      if(!this.setup.title.trim()||!this.setup.author.trim()) return;
      this.book={title:this.setup.title.trim(),author:this.setup.author.trim(),
        tags:[],chapters:[],characters:[],character_relations:[],questions:[],locations:[],topics:[]};
      this.canvasNodes=[];this.eventOrders=[];this.tagInputs={};this.dirty=false;
    },
    loadSavedBook(data){
      const {book,canvasNodes,eventOrders}=deserializeBook(data);
      this.book=book;this.canvasNodes=canvasNodes;this.eventOrders=eventOrders;
      this.tagInputs={};
      this.currentOrderId=null;this.currentLocId=null;this.currentTopicId=null;
      this.activeTab='Characters';this.dirty=false;
    },
    doBackToBooks(){
      this.book=null;this.canvasNodes=[];this.eventOrders=[];
      this.currentOrderId=null;this.currentLocId=null;this.currentTopicId=null;
      this.setup={title:'',author:''};this.dirty=false;this.fetchBooks();
    },
    backToBooks(){this.guardAction(()=>this.doBackToBooks());},
    /* ── characters ──────────────────── */
    addCharacter(){
      if(!this.book||!this.newChar.name.trim()) return;
      const id=uid();
      this.book.characters.push({id,name:this.newChar.name.trim(),description:this.newChar.description.trim()||null,tags:[]});
      this.tagInputs[id]='';
      this.newChar={open:false,name:'',description:''};this.mark();
    },
    removeCharacter(id){
      this.book.characters=this.book.characters.filter(c=>c.id!==id);
      this.book.character_relations=this.book.character_relations.filter(r=>r.character1Id!==id&&r.character2Id!==id);
      this.canvasNodes=this.canvasNodes.filter(n=>n.characterId!==id);
      this.eventOrders.forEach(o=>{o.characterColumns=o.characterColumns.filter(c=>c.characterId!==id);});
      delete this.tagInputs[id];
      this.mark();
    },
    addTagToChar(ch){
      const t=(this.tagInputs[ch.id]||'').trim();
      if(!t)return;
      if(!ch.tags) ch.tags=[];
      // Force unique array reference for the character
      ch.tags = [...ch.tags];
      if(!ch.tags.includes(t)){ch.tags.push(t);this.mark();}

      if(!this.book.tags) this.book.tags=[];
      if(!this.book.tags.includes(t)){this.book.tags.push(t);this.mark();}
      this.tagInputs[ch.id]='';
      this.tagDropdownCharId=null;
    },
    openTagSuggestions(ch){
      this.tagDropdownCharId=ch.id;
    },
    filteredTagsFor(ch){
      const existing=new Set(ch.tags||[]);
      const f=(this.tagInputs[ch.id]||'').toLowerCase();
      // Only show tags from the book that the character doesn't have yet
      return (this.book.tags||[]).filter(t=>!existing.has(t)&&(!f||t.toLowerCase().includes(f)));
    },
    pickTag(ch,tag){
      if(!ch.tags) ch.tags=[];
      ch.tags = [...ch.tags];
      if(!ch.tags.includes(tag)){ch.tags.push(tag);this.mark();}

      if(!this.book.tags) this.book.tags=[];
      if(!this.book.tags.includes(tag)){this.book.tags.push(tag);this.mark();}
      this.tagInputs[ch.id]='';
      this.tagDropdownCharId=null;
    },
    removeTagFromChar(ch,tag){
      ch.tags=(ch.tags||[]).filter(t=>t!==tag);this.mark();
    },
    charName(id){if(!id) return this.t('General'); return this.book?.characters.find(c=>c.id===id)?.name||this.t('Unknown');},
    /* ── canvas ──────────────────────── */
    onChipDrag(ch,e){e.dataTransfer.effectAllowed='copy';e.dataTransfer.setData('text/plain',ch.id);},
    onCanvasDrop(e){
      const id=e.dataTransfer.getData('text/plain');
      if(!id||this.canvasNodes.some(n=>n.characterId===id)) return;
      const r=this.$refs.canvasPane.getBoundingClientRect();
      this.canvasNodes.push({characterId:id,x:Math.max(8,e.clientX-r.left-60),y:Math.max(8,e.clientY-r.top-18)});
      this.mark();
    },
    onNodeMD(node,e){
      if(this.linkMode) return;
      // On plain mousedown (no modifier): if this node isn't selected, make it the only selection.
      // With Shift held we leave selection alone — onNodeClick will toggle it.
      if(!e.shiftKey){
        if(!this.selectedNodeIds.includes(node.characterId)){
          this.selectedNodeIds=[node.characterId];
        }
      }
      const startX=e.clientX,startY=e.clientY;
      // Snapshot start positions for all currently selected nodes
      const starts=this.canvasNodes
        .filter(n=>this.selectedNodeIds.includes(n.characterId))
        .map(n=>({node:n,x0:n.x,y0:n.y}));
      const mv=ev=>{
        const dx=ev.clientX-startX,dy=ev.clientY-startY;
        starts.forEach(({node,x0,y0})=>{node.x=Math.max(0,x0+dx);node.y=Math.max(0,y0+dy);});
      };
      const up=()=>{document.removeEventListener('mousemove',mv);document.removeEventListener('mouseup',up);this.mark();};
      document.addEventListener('mousemove',mv);document.addEventListener('mouseup',up);
    },
    onNodeClick(node,e){
      if(this.linkMode){
        if(!this.linkSourceId){this.linkSourceId=node.characterId;}
        else if(this.linkSourceId!==node.characterId){
          this.linkModal={open:true,c1:this.linkSourceId,c2:node.characterId,type:''};
          this.$nextTick(()=>{this.$refs.linkTypeInput?.focus();});
        }
        return;
      }
      // shift+click toggles selection
      if(e&&e.shiftKey){
        const idx=this.selectedNodeIds.indexOf(node.characterId);
        if(idx===-1) this.selectedNodeIds.push(node.characterId);
        else this.selectedNodeIds.splice(idx,1);
      } else {
        this.selectedNodeIds=[node.characterId];
      }
    },
    confirmLink(){
      if(!this.linkModal.type.trim()) return;
      this.book.character_relations.push({id:uid(),character1Id:this.linkModal.c1,character2Id:this.linkModal.c2,relationType:this.linkModal.type.trim()});
      this.linkModal={open:false,c1:null,c2:null,type:''};this.linkMode=false;this.linkSourceId=null;this.mark();
    },
    cancelLinkModal(){this.linkModal={open:false,c1:null,c2:null,type:''};this.linkMode=false;this.linkSourceId=null;},
    removeRelation(i){this.book.character_relations.splice(i,1);this.mark();},
    removeNode(node){
      this.canvasNodes=this.canvasNodes.filter(n=>n!==node);
      this.book.character_relations=this.book.character_relations.filter(r=>r.character1Id!==node.characterId&&r.character2Id!==node.characterId);
      this.mark();
    },
    /* ── event orders ────────────────── */
    addEventOrder(){
      const o={id:uid(),name:'Event Order '+(this.eventOrders.length+1),
        timelineConfig:{mode:'custom',pixels_per_marker:80,custom_labels:['Start','Middle','End'],
          clock_start:'08:00',clock_end:'20:00',clock_interval_min:60,
          week_start:1,week_end:12,date_start:'2026-01-01',date_end:'2026-01-31',date_interval_days:1},
        characterColumns:[]};
      this.eventOrders.push(o);this.currentOrderId=o.id;this.mark();
    },
    deleteEventOrder(id){
      this.eventOrders=this.eventOrders.filter(o=>o.id!==id);
      if(this.currentOrderId===id) this.currentOrderId=null;
      this.mark();
    },
    selectOrder(id){this.currentOrderId=id;this.tlConfigOpen=false;},
    // drag character chip into timeline
    onTlCharDrop(e){
      const id=e.dataTransfer.getData('text/plain');
      if(!id||!this.currentOrder) return;
      if(e.dataTransfer.types.includes('text/col-reorder')) return;
      if(this.currentOrder.characterColumns.some(c=>c.characterId===id)) return;
      const newCol={characterId:id,events:[]};
      // find insertion index from drop X position
      const scrollEl=this.$refs.tlScroll;
      if(scrollEl){
        const dropX=e.clientX-scrollEl.getBoundingClientRect().left+scrollEl.scrollLeft;
        const axisW=90;
        const cols=this.currentOrder.characterColumns;
        if(cols.length>0){
          const colW=scrollEl.querySelector('.tl-col');
          const cw=colW?colW.offsetWidth:220;
          const idx=Math.min(cols.length,Math.max(0,Math.round((dropX-axisW)/cw)));
          cols.splice(idx,0,newCol);
        } else {
          cols.push(newCol);
        }
      } else {
        this.currentOrder.characterColumns.push(newCol);
      }
      this.mark();
    },
    addGeneralColumn(){
      if(!this.currentOrder) return;
      if(this.currentOrder.characterColumns.some(c=>c.characterId===null)) return;
      this.currentOrder.characterColumns.push({characterId:null,events:[]});this.mark();
    },
    toggleEoTag(tag){
      const i=this.eoSelectedTags.indexOf(tag);
      if(i>=0) this.eoSelectedTags.splice(i,1);
      else this.eoSelectedTags.push(tag);
    },
    addCharsBySelectedTags(){
      if(!this.eoSelectedTags.length||!this.currentOrder) return;
      const chars=this.book.characters.filter(c=>this.eoSelectedTags.every(tag=>(c.tags||[]).includes(tag)));
      chars.forEach(ch=>{
        if(!this.currentOrder.characterColumns.some(c=>c.characterId===ch.id)){
          this.currentOrder.characterColumns.push({characterId:ch.id,events:[]});
        }
      });
      this.mark();
    },
    removeColumn(col){
      if(!this.currentOrder) return;
      this.currentOrder.characterColumns=this.currentOrder.characterColumns.filter(c=>c!==col);this.mark();
    },
    onColDragStart(col,e){
      const cols=this.currentOrder.characterColumns;
      this.colDragIdx=cols.indexOf(col);
      e.dataTransfer.effectAllowed='move';
      e.dataTransfer.setData('text/col-reorder','1');
    },
    onColDragOver(col,e){
      if(e.dataTransfer.types.includes('text/col-reorder')){
        if(this.colDragIdx===null) return;
        e.preventDefault(); e.dataTransfer.dropEffect='move';
      } else if(e.dataTransfer.types.includes('text/plain')){
        e.preventDefault(); e.dataTransfer.dropEffect='copy';
      }
    },
    onColDrop(col,e){
      // column reorder
      if(e.dataTransfer.types.includes('text/col-reorder')&&this.colDragIdx!==null){
        e.preventDefault(); e.stopPropagation();
        const cols=this.currentOrder.characterColumns;
        const toIdx=cols.indexOf(col);
        if(toIdx===-1||this.colDragIdx===toIdx){this.colDragIdx=null;return;}
        const [moved]=cols.splice(this.colDragIdx,1);
        cols.splice(toIdx,0,moved);
        this.colDragIdx=null;this.mark();
        return;
      }
      // character chip drop onto a column header → insert before that column
      const id=e.dataTransfer.getData('text/plain');
      if(id&&this.currentOrder&&!this.currentOrder.characterColumns.some(c=>c.characterId===id)){
        e.preventDefault(); e.stopPropagation();
        const cols=this.currentOrder.characterColumns;
        const toIdx=cols.indexOf(col);
        cols.splice(toIdx===-1?cols.length:toIdx,0,{characterId:id,events:[]});
        this.mark();
      }
    },
    onColDragEnd(){this.colDragIdx=null;},
    // timeline config helpers
    addCustomLabel(){
      const cfg=this.currentOrder.timelineConfig;
      if(!cfg.custom_labels) cfg.custom_labels=[];
      cfg.custom_labels.push('Label '+(cfg.custom_labels.length+1));this.mark();
    },
    insertCustomLabel(i){
      const cfg=this.currentOrder.timelineConfig;
      if(!cfg.custom_labels) cfg.custom_labels=[];
      cfg.custom_labels.splice(i,0,'New');this.mark();
    },
    removeCustomLabel(i){this.currentOrder.timelineConfig.custom_labels.splice(i,1);this.mark();},
    // zoom timeline via Ctrl+scroll
    onTlWheel(e){
      if(!this.currentOrder||!e.ctrlKey) return;
      e.preventDefault();
      this.zoomTl(e.deltaY>0?-10:10);
    },
    zoomTl(d){
      if(!this.currentOrder) return;
      const cfg=this.currentOrder.timelineConfig;
      const oldPpm=cfg.pixels_per_marker||80;
      const newPpm=clamp(oldPpm+d,30,300);
      if(newPpm===oldPpm) return;
      const ratio=newPpm/oldPpm;
      this.currentOrder.characterColumns.forEach(col=>{
        col.events.forEach(evt=>{
          evt.yPos=Math.round(evt.yPos*ratio);
          evt.height=Math.max(24,Math.round(evt.height*ratio));
        });
      });
      cfg.pixels_per_marker=newPpm;
      if(cfg.gap_sizes) cfg.gap_sizes=cfg.gap_sizes.map(g=>clamp(Math.round(g*ratio),30,600));
      this.mark();
    },
    // events
    onTlColDblClick(col,e){
      const rect=e.currentTarget.getBoundingClientRect();
      const y=e.clientY-rect.top;
      const markers=this.currentMarkers;
      const cfg=this.currentOrder.timelineConfig;
      const ev={id:uid(),description:'',yPos:Math.max(0,y-25),height:50,time:timeFromY(y,markers,cfg),locationId:null};
      col.events.push(ev);this.editingEvtId=ev.id;this.mark();
    },
    onEvtDrag(evt,e){
      e.preventDefault();e.stopPropagation();
      const startY=e.clientY,startPos=evt.yPos;
      const markers=this.currentMarkers,cfg=this.currentOrder.timelineConfig;
      const mv=me=>{evt.yPos=clamp(startPos+me.clientY-startY,0,this.totalTlHeight-evt.height);evt.time=timeFromY(evt.yPos+evt.height/2,markers,cfg);};
      const up=()=>{document.removeEventListener('mousemove',mv);document.removeEventListener('mouseup',up);this.mark();};
      document.addEventListener('mousemove',mv);document.addEventListener('mouseup',up);
    },
    onEvtResize(evt,e){
      e.preventDefault();e.stopPropagation();
      const startY=e.clientY,startH=evt.height;
      const markers=this.currentMarkers,cfg=this.currentOrder.timelineConfig;
      const mv=me=>{evt.height=clamp(startH+me.clientY-startY,24,600);evt.time=timeFromY(evt.yPos+evt.height/2,markers,cfg);};
      const up=()=>{document.removeEventListener('mousemove',mv);document.removeEventListener('mouseup',up);this.mark();};
      document.addEventListener('mousemove',mv);document.addEventListener('mouseup',up);
    },
    removeEvt(col,evt){col.events=col.events.filter(e=>e!==evt);this.mark();},
    locName(id){if(!id||!this.book) return '';const l=this.book.locations.find(l=>l.id===id);return l?l.name:'';},
    goToLocation(locId){
      if(!locId||!this.book) return;
      if(!this.book.locations.find(l=>l.id===locId)) return;
      if(this.dirty) this.showToast(this.t('Remember to save your changes!'));
      this.activeTab='Locations';this.currentLocId=locId;
      this.drawTool='select';this.selectedObjId=null;this.drawingPts=[];
    },
    /* ── questions ───────────────────── */
    addQuestion(){
      if(!this.book||!this.newQText.trim()) return;
      this.book.questions.push({id:uid(),text:this.newQText.trim(),answer:'',answered:false});
      this.newQText='';this.mark();
    },
    removeQuestion(q){this.book.questions=this.book.questions.filter(x=>x!==q);this.mark();},
    qClass(q){if(q.answered) return 'q-green';if(q.answer&&q.answer.trim()) return 'q-yellow';return 'q-red';},
    /* ── locations ───────────────────── */
    addLocation(){
      if(!this.newLoc.name.trim()) return;
      const loc={id:uid(),name:this.newLoc.name.trim(),description:this.newLoc.description.trim(),
        width:Number(this.newLoc.width)||10,height:Number(this.newLoc.height)||10,unit:this.newLoc.unit||'m',objects:[]};
      this.book.locations.push(loc);
      this.newLoc={open:false,name:'',description:'',width:10,height:10,unit:'m'};
      this.currentLocId=loc.id;this.mark();
    },
    openLocation(id){this.currentLocId=id;this.drawTool='select';this.selectedObjId=null;this.drawingPts=[];},
    closeLocation(){this.currentLocId=null;this.selectedObjId=null;this.drawingPts=[];},
    deleteLocation(id){this.book.locations=this.book.locations.filter(l=>l.id!==id);if(this.currentLocId===id)this.currentLocId=null;this.mark();},
    // drawing helpers
    svgPos(e){
      const svg=this.$refs.locSvg;if(!svg) return {x:0,y:0};
      const r=svg.getBoundingClientRect();return {x:e.clientX-r.left,y:e.clientY-r.top};
    },
    locCanvasW(){return Math.max(600,this.currentLoc?this.currentLoc.width*8:600);},
    locCanvasH(){return Math.max(400,this.currentLoc?this.currentLoc.height*8:400);},
    onLocMD(e){
      const pos=this.svgPos(e);
      if(['rectangle','ellipse','circle'].includes(this.drawTool)){
        this.drawStart=pos;this.isDrawingShape=true;return;
      }
      if(this.drawTool==='select') this.selectedObjId=null;
    },
    onLocMM(e){this.cursorPos=this.svgPos(e);},
    onLocMU(e){
      if(this.isDrawingShape&&this.drawStart){
        const pos=this.svgPos(e);
        const x1=Math.min(this.drawStart.x,pos.x),y1=Math.min(this.drawStart.y,pos.y);
        const w=Math.abs(pos.x-this.drawStart.x),h=Math.abs(pos.y-this.drawStart.y);
        if(w>4||h>4){
          const obj={id:uid(),type:this.drawTool,x:x1+w/2,y:y1+h/2,
            width:this.drawTool==='circle'?Math.max(w,h):w,
            height:this.drawTool==='circle'?Math.max(w,h):h,
            color:this.drawTool==='circle'?'#bdc3c7':'#dfe6e9',stroke:'#636e72',strokeWidth:2,name:'',scale:1,points:[]};
          this.currentLoc.objects.push(obj);this.selectedObjId=obj.id;this.mark();
        }
        this.drawStart=null;this.isDrawingShape=false;
      }
    },
    onLocClick(e){
      const pos=this.svgPos(e);
      if(ALL_ICONS.includes(this.drawTool)){
        const obj={id:uid(),type:this.drawTool,x:pos.x,y:pos.y,
          width:40,height:40,scale:1,color:ICON_DEFAULTS[this.drawTool],
          stroke:'#333',strokeWidth:1,name:'',points:[]};
        this.currentLoc.objects.push(obj);this.selectedObjId=obj.id;this.mark();return;
      }
      if(ALL_AREAS.includes(this.drawTool)){
        if(this.drawingPts.length>2){
          const f=this.drawingPts[0];
          if(Math.hypot(pos.x-f[0],pos.y-f[1])<18){this.finishArea();return;}
        }
        this.drawingPts.push([pos.x,pos.y]);return;
      }
    },
    onLocDblClick(e){
      if(ALL_AREAS.includes(this.drawTool)&&this.drawingPts.length>=2) this.finishArea();
    },
    finishArea(){
      if(this.drawingPts.length<2){this.drawingPts=[];return;}
      const d=AREA_DEFAULTS[this.drawTool]||AREA_DEFAULTS.lake;
      const obj={id:uid(),type:this.drawTool,x:0,y:0,width:0,height:0,scale:1,
        color:d.color,stroke:d.stroke,strokeWidth:d.strokeWidth,name:'',points:[...this.drawingPts]};
      this.currentLoc.objects.push(obj);this.selectedObjId=obj.id;this.drawingPts=[];this.mark();
    },
    selectDrawTool(t){this.drawTool=t;this.drawingPts=[];this.isDrawingShape=false;this.drawStart=null;},
    onObjMD(obj,e){
      if(this.drawTool!=='select') return;
      e.stopPropagation();e.preventDefault();this.selectedObjId=obj.id;
      const start=this.svgPos(e),sx=obj.x,sy=obj.y;
      const sp=obj.points?obj.points.map(p=>[...p]):null;
      const mv=me=>{
        const p=this.svgPos(me),dx=p.x-start.x,dy=p.y-start.y;
        if(sp&&sp.length){obj.points=sp.map(pt=>[pt[0]+dx,pt[1]+dy]);}
        else{obj.x=sx+dx;obj.y=sy+dy;}
      };
      const up=()=>{document.removeEventListener('mousemove',mv);document.removeEventListener('mouseup',up);this.mark();};
      document.addEventListener('mousemove',mv);document.addEventListener('mouseup',up);
    },
    deleteSelectedObj(){
      if(!this.currentLoc||!this.selectedObjId) return;
      this.currentLoc.objects=this.currentLoc.objects.filter(o=>o.id!==this.selectedObjId);
      this.selectedObjId=null;this.mark();
    },
    polyPoints(pts){return pts.map(p=>p.join(',')).join(' ');},
    /* ── notes / topics ──────────────── */
    addTopic(){
      if(!this.book||!this.newTopicName.trim()) return;
      const t={id:uid(),name:this.newTopicName.trim(),notes:[],urlLinks:[]};
      this.book.topics.push(t);this.currentTopicId=t.id;this.newTopicName='';this.mark();
    },
    removeTopic(t){
      this.book.topics=this.book.topics.filter(x=>x.id!==t.id);
      if(this.currentTopicId===t.id) this.currentTopicId=null;this.mark();
    },
    addNote(){
      if(!this.currentTopic) return;
      this.currentTopic.notes.push({id:uid(),text:'',color:'#fff9c4'});this.mark();
    },
    removeNote(n){
      if(!this.currentTopic) return;
      this.currentTopic.notes=this.currentTopic.notes.filter(x=>x.id!==n.id);this.mark();
    },
    addUrl(){
      if(!this.currentTopic||!this.newUrl.trim()) return;
      this.currentTopic.urlLinks.push(this.newUrl.trim());this.newUrl='';this.mark();
    },
    removeUrl(i){
      if(!this.currentTopic) return;
      this.currentTopic.urlLinks.splice(i,1);this.mark();
    },
    /* ── keyboard ────────────────────── */
    onKey(e){
      if(e.key==='Delete'||e.key==='Backspace'){
        if(this.activeTab==='Locations'&&this.selectedObjId&&document.activeElement.tagName!=='INPUT'&&document.activeElement.tagName!=='TEXTAREA')
          this.deleteSelectedObj();
      }
    },
  },

  /* ═══════════════════════════════════════════════════════════════
     Template
     ═══════════════════════════════════════════════════════════════ */
  template:`
<div class="app-root">

<!-- LOADING -->
<div v-if="loading" class="loading-screen"><div class="ld-inner"><img src="logo.png" style="width: 72px; height: 72px;" class="brand-logo" alt="Autorino"/><h2 class="brand-name">Autorino</h2><p class="muted">{{t('Loading…')}}</p></div></div>

<!-- BOOK SELECTION -->
<div v-else-if="!book" class="setup-screen">
  <h1 class="brand"><img src="logo.png" style="width: 96px; height: 96px;" class="brand-logo-sm" alt=""/> <span class="brand-name">Autorino</span></h1>
  <div v-if="savedBooks.length" class="saved-section">
    <h2>{{t('Your Books')}}</h2>
    <div class="book-cards">
      <div v-for="(b,i) in savedBooks" :key="i" class="book-card" @click="loadSavedBook(b)">
        <h4>{{b.title}}</h4>
        <p class="bc-author">{{t('by')}} {{b.author}}</p>
        <p class="bc-meta">{{(b.characters||[]).length}} {{t('chars')}} · {{(b.questions||[]).length}} {{t('questions')}} · {{(b.locations||[]).length}} {{t('locations')}}</p>
      </div>
    </div>
  </div>
  <div class="create-section">
    <h2>{{savedBooks.length?t('Or create a new book'):t('Create your first book')}}</h2>
    <div class="setup-grid">
      <div class="field"><label>{{t('Title')}}</label><input v-model="setup.title" :placeholder="t('e.g. The Great Adventure')"/></div>
      <div class="field"><label>{{t('Author')}}</label><input v-model="setup.author" :placeholder="t('e.g. Jane Doe')"/></div>
    </div>
    <div class="form-actions" style="margin-top:20px"><button class="primary" @click="createBook">{{t('Create Book')}}</button></div>
  </div>
  <div class="lang-switcher" style="justify-content:center;border-top:none;padding-top:24px">
    <img src="flag_images/english.png" class="lang-flag" :class="{active:locale==='en'}" @click="locale='en'" alt="English" title="English"/>
    <img src="flag_images/german.png" class="lang-flag" :class="{active:locale==='de'}" @click="locale='de'" alt="Deutsch" title="Deutsch"/>
  </div>
</div>

<!-- APP SHELL -->
<div v-else class="app-shell">
  <aside class="sidebar">
    <div class="sb-top"><img src="logo.png" style="width: 108px; height: 108px;" class="sb-logo" alt=""/><div><h2 v-if="!editingTitle" @click="startEditTitle" class="sb-title-display" :title="t('Click to rename')">{{book.title}}</h2><input v-else ref="titleInput" class="sb-title-input" v-model="titleDraft" @keydown.enter="commitTitleEdit" @keydown.esc="cancelTitleEdit" @blur="commitTitleEdit"/><p class="meta">{{t('by')}} {{book.author}}</p></div></div>
    <nav class="tab-list">
      <button v-for="tab in tabs" :key="tab" class="tab-btn" :class="{active:activeTab===tab}" @click="activeTab=tab">{{t(tab)}}</button>
      <button class="back-btn" @click="backToBooks">{{t('← All Books')}}</button>
      <div v-if="dirty" class="dirty-badge" style="margin-top: 4px; font-size: 11px; padding: 4px 8px;">{{t('● Unsaved changes')}}</div>
    </nav>
    <div class="lang-switcher">
      <img src="flag_images/english.png" class="lang-flag" :class="{active:locale==='en'}" @click="locale='en'" alt="English" title="English"/>
      <img src="flag_images/german.png" class="lang-flag" :class="{active:locale==='de'}" @click="locale='de'" alt="Deutsch" title="Deutsch"/>
    </div>
  </aside>

  <main class="main">

  <!-- ═══════════════ CHARACTERS ═══════════════ -->
  <section v-if="activeTab==='Characters'">
    <div class="tab-header"><h3>{{t('Characters')}}</h3>
      <div class="tab-actions"><button @click="newChar.open=true">{{t('+ Add Character')}}</button><button @click="openImportModal('characters')">{{t('Import Characters')}}</button><button class="save-btn" @click="saveBook">{{t('💾 Save')}}</button></div>
    </div>

    <div v-if="newChar.open" class="form-card">
      <h4>{{t('New Character')}}</h4>
      <div class="field"><label>{{t('Name')}}</label><input v-model="newChar.name" :placeholder="t('Name')"/></div>
      <div class="field"><label>{{t('Description')}}</label><textarea v-model="newChar.description" :placeholder="t('Description')+'…'"></textarea></div>
      <div class="form-actions"><button class="primary" @click="addCharacter">{{t('Add')}}</button><button @click="newChar.open=false">{{t('Cancel')}}</button></div>
    </div>

    <div v-if="book.characters.length" class="char-grid">
      <div v-for="ch in book.characters" :key="ch.id" class="char-card"
           :style="{borderColor:charColor(ch.id),background:'#fff'}">
        <div class="char-color-bar" :style="{background:charColor(ch.id)}"></div>
        <div class="char-body">
          <div class="field" style="display:flex;gap:10px;align-items:start">
            <div style="flex:1"><label>{{t('Name')}}</label><input v-model="ch.name" @input="mark()"/></div>
            <button class="icon-btn danger-txt" style="margin-top:20px" @click="removeCharacter(ch.id)" :title="t('Delete character')">🗑</button>
          </div>
          <div class="field"><label>{{t('Description')}}</label><textarea v-model="ch.description" @input="mark()" rows="2"></textarea></div>
          <div class="field"><label>{{t('Tags')}}</label>
            <div class="char-tag-list">
              <span v-for="tag in (ch.tags||[])" :key="tag" class="char-tag" :style="{borderColor:charColor(ch.id)}">
                {{tag}} <button class="char-tag-x" @click="removeTagFromChar(ch,tag)">✕</button>
              </span>
            </div>
            <div class="char-tag-add" style="position:relative">
              <input v-model="tagInputs[ch.id]" :placeholder="t('Add tag…')"
                     @focus="openTagSuggestions(ch)"
                     @blur="setTimeout(()=>{if(tagDropdownCharId===ch.id)tagDropdownCharId=null},120)"
                     @keyup.enter="addTagToChar(ch)"/>
              <button @click="addTagToChar(ch)">+</button>
              <div v-if="tagDropdownCharId===ch.id && filteredTagsFor(ch).length" class="tag-dropdown">
                <button v-for="tg in filteredTagsFor(ch)" :key="tg" type="button" class="tag-dropdown-item" @mousedown.prevent="pickTag(ch,tg)">{{tg}}</button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <div v-else class="empty-state"><p>{{t('No characters yet.')}}</p></div>

    <!-- Relationship map -->
    <div class="section-divider"></div>
    <div class="map-header">
      <h3>{{t('Character Relationship Map')}}</h3>
      <div class="map-actions">
        <button @click="growCanvasPane" :title="t('＋ Wider')">{{t('＋ Wider')}}</button>
        <button v-if="canvasPaneWidth>0" @click="resetCanvasPane" :title="t('Reset width')">{{t('Reset width')}}</button>
        <button @click="growCanvasWrap" :title="t('＋ Taller')">{{t('＋ Taller')}}</button>
        <button v-if="canvasWrapHeight>0" @click="resetCanvasWrap" :title="t('Reset height')">{{t('Reset height')}}</button>
        <button v-if="!linkMode" @click="linkMode=true;linkSourceId=null" :disabled="canvasNodes.length<2">{{t('🔗 Add Link')}}</button>
        <button v-else class="danger" @click="linkMode=false;linkSourceId=null">{{t('Cancel')}}</button>
      </div>
    </div>
    <p v-if="linkMode" class="link-hint">{{t('Click two characters on the map to link them.')}}</p>

    <div class="canvas-wrap" ref="canvasWrap" :style="canvasWrapHeight?{height:canvasWrapHeight+'px'}:{}">
      <div class="canvas-chips">
        <div class="canvas-chips-label">{{t('Drag onto map ↓')}}</div>
        <div v-for="ch in book.characters" :key="'cc'+ch.id" class="cc-chip"
             :style="{borderColor:charColor(ch.id),background:canvasNodes.some(n=>n.characterId===ch.id)?'#eee':'#fff'}"
             :class="{placed:canvasNodes.some(n=>n.characterId===ch.id)}"
             draggable="true" @dragstart="onChipDrag(ch,$event)">{{ch.name}}</div>
      </div>
      <div class="canvas-pane" ref="canvasPane" :style="canvasPaneWidth?{flex:'none',width:canvasPaneWidth+'px'}:{}" @dragover.prevent @drop.prevent="onCanvasDrop($event)" @click.self="selectedNodeIds=[]">
        <svg class="canvas-svg">
          <g v-for="lk in computedLinks" :key="lk.id">
            <line :x1="lk.x1" :y1="lk.y1" :x2="lk.x2" :y2="lk.y2" stroke="#7aa5f0" stroke-width="2"/>
            <text :x="(lk.x1+lk.x2)/2" :y="(lk.y1+lk.y2)/2+4" text-anchor="middle" font-size="11" font-weight="600" fill="#4a6fa5"
                  stroke="#fff" stroke-width="3" paint-order="stroke">{{lk.label}}</text>
          </g>
        </svg>
        <div v-for="node in canvasNodes" :key="'n'+node.characterId" class="canvas-node"
             :class="{'link-sel':linkSourceId===node.characterId,'node-selected':selectedNodeIds.includes(node.characterId)&&!linkMode}"
             :style="{left:node.x+'px',top:node.y+'px',borderColor:charColor(node.characterId),background:charColorLight(node.characterId)}"
             @mousedown.prevent="onNodeMD(node,$event)" @click.stop="onNodeClick(node,$event)">
          {{charName(node.characterId)}}
          <span class="node-x" @click.stop="removeNode(node)">✕</span>
        </div>
        <div v-if="!canvasNodes.length" class="canvas-empty"><p>{{t('🗺️ Drop characters here')}}</p></div>
      </div>
    </div>

    <div v-if="book.character_relations.length" class="rel-list">
      <h4>{{t('Relations')}}</h4>
      <div v-for="(rel,i) in book.character_relations" :key="rel.id" class="rel-item">
        <span class="rel-name" :style="{color:charColor(rel.character1Id)}">{{charName(rel.character1Id)}}</span>
        <span class="rel-label">{{rel.relationType}}</span>
        <span class="rel-name" :style="{color:charColor(rel.character2Id)}">{{charName(rel.character2Id)}}</span>
        <button class="icon-btn" @click="removeRelation(i)">✕</button>
      </div>
    </div>
  </section>

  <!-- ═══════════════ EVENT ORDERS ═══════════════ -->
  <section v-if="activeTab==='Event orders'">
    <div class="tab-header"><h3>{{t('Event Orders')}}</h3>
      <div class="tab-actions"><button class="save-btn" @click="saveBook">{{t('💾 Save')}}</button></div>
    </div>

    <div class="eo-list">
      <div v-for="(o,i) in eventOrders" :key="o.id" class="eo-item">
        <div><strong>{{o.name}}</strong> <span class="small-note">· {{o.characterColumns.length}} {{t('columns')}}</span></div>
        <div class="eo-item-actions">
          <button @click="selectOrder(o.id)">{{t('Open')}}</button>
          <button class="icon-btn danger-txt" @click="deleteEventOrder(o.id)" :title="t('Delete event order')">🗑</button>
        </div>
      </div>
      <button @click="addEventOrder">{{t('+ New Event Order')}}</button>
    </div>

    <div v-if="currentOrder" class="tl-editor">
      <!-- toolbar -->
      <div class="tl-toolbar">
        <input v-model="currentOrder.name" class="tl-name-input" @input="mark()"/>
        <button @click="tlConfigOpen=!tlConfigOpen">{{t('⚙ Timeline')}}</button>
        <div class="tl-zoom-controls">
          <button class="icon-btn" @click="zoomTl(-10)" title="Zoom out">−</button>
          <span class="small-note">{{currentOrder.timelineConfig.pixels_per_marker}}px</span>
          <button class="icon-btn" @click="zoomTl(10)" title="Zoom in">+</button>
        </div>
      </div>

      <!-- timeline config panel -->
      <div v-if="tlConfigOpen" class="tl-config">
        <h4>{{t('Timeline Configuration')}}</h4>
        <div class="fg3">
          <div class="field"><label>{{t('Mode')}}</label>
            <select v-model="currentOrder.timelineConfig.mode" @change="mark()">
              <option value="custom">{{t('Custom Labels')}}</option>
              <option value="clock">{{t('Clock (hours)')}}</option>
              <option value="weekday">{{t('Days of Week')}}</option>
              <option value="week">{{t('Weeks')}}</option>
              <option value="month">{{t('Months')}}</option>
              <option value="date">{{t('Dates')}}</option>
            </select>
          </div>
          <div class="field"><label>{{t('Pixels per marker')}}</label>
            <input type="number" v-model.number="currentOrder.timelineConfig.pixels_per_marker" min="30" max="300" @input="mark()"/>
          </div>
        </div>
        <!-- clock -->
        <div v-if="currentOrder.timelineConfig.mode==='clock'" class="fg3">
          <div class="field"><label>{{t('Start')}}</label><input v-model="currentOrder.timelineConfig.clock_start" placeholder="08:00" @input="mark()"/></div>
          <div class="field"><label>{{t('End')}}</label><input v-model="currentOrder.timelineConfig.clock_end" placeholder="20:00" @input="mark()"/></div>
          <div class="field"><label>{{t('Interval (min)')}}</label><input type="number" v-model.number="currentOrder.timelineConfig.clock_interval_min" min="5" @input="mark()"/></div>
        </div>
        <!-- week -->
        <div v-if="currentOrder.timelineConfig.mode==='week'" class="fg2">
          <div class="field"><label>{{t('Start week')}}</label><input type="number" v-model.number="currentOrder.timelineConfig.week_start" min="1" @input="mark()"/></div>
          <div class="field"><label>{{t('End week')}}</label><input type="number" v-model.number="currentOrder.timelineConfig.week_end" min="1" @input="mark()"/></div>
        </div>
        <!-- date -->
        <div v-if="currentOrder.timelineConfig.mode==='date'" class="fg3">
          <div class="field"><label>{{t('Start date')}}</label><input type="date" v-model="currentOrder.timelineConfig.date_start" @input="mark()"/></div>
          <div class="field"><label>{{t('End date')}}</label><input type="date" v-model="currentOrder.timelineConfig.date_end" @input="mark()"/></div>
          <div class="field"><label>{{t('Interval (days)')}}</label><input type="number" v-model.number="currentOrder.timelineConfig.date_interval_days" min="1" @input="mark()"/></div>
        </div>
        <!-- custom labels with insert-anywhere -->
        <div v-if="currentOrder.timelineConfig.mode==='custom'" class="custom-labels">
          <label>{{t('Labels (top → bottom)')}}</label>
          <button class="cl-insert-btn" @click="insertCustomLabel(0)" :title="t('+ Insert here')">{{t('+ Insert here')}}</button>
          <template v-for="(lb,i) in currentOrder.timelineConfig.custom_labels" :key="'cl'+i">
            <div class="cl-row">
              <input :value="lb" @input="currentOrder.timelineConfig.custom_labels[i]=$event.target.value;mark()"/>
              <button class="icon-btn" @click="removeCustomLabel(i)">✕</button>
            </div>
            <button class="cl-insert-btn" @click="insertCustomLabel(i+1)" :title="t('+ Insert here')">{{t('+ Insert here')}}</button>
          </template>
        </div>
        <p class="small-note" style="margin-top:10px">{{t('Tip: Ctrl + scroll wheel on the timeline to zoom in/out.')}}</p>
      </div>

      <!-- drop zone for characters + General -->
      <div class="tl-char-pool">
        <span class="small-note">{{t('Drag characters here to add columns →')}}</span>
        <div v-for="ch in book.characters" :key="'tc'+ch.id" class="tc-chip"
             :style="{borderColor:charColor(ch.id)}"
             :class="{used:currentOrder.characterColumns.some(c=>c.characterId===ch.id)}"
             draggable="true" @dragstart="e=>{e.dataTransfer.setData('text/plain',ch.id)}">
          {{ch.name}}
        </div>
        <button class="tc-general-btn" @click="addGeneralColumn"
                :disabled="currentOrder.characterColumns.some(c=>c.characterId===null)">
          + {{t('General')}}
        </button>
      </div>
      <div v-if="allTags.length" class="eo-tag-chips">
        <span class="small-note" style="margin-right:4px">{{t('Filter by tags:')}}</span>
        <span v-for="tg in allTags" :key="tg" class="eo-tag-chip" :class="{active:eoSelectedTags.includes(tg)}" @click="toggleEoTag(tg)">{{tg}}</span>
        <button v-if="eoSelectedTags.length" style="margin-left:8px;font-size:12px" @click="addCharsBySelectedTags">+ {{t('Add matching characters')}}</button>
        <button v-if="eoSelectedTags.length" class="icon-btn" style="margin-left:4px;font-size:11px" @click="eoSelectedTags=[]" :title="t('Clear tag filter')">✕ {{t('Clear')}}</button>
      </div>

      <!-- timeline grid -->
      <div class="tl-scroll" ref="tlScroll" @dragover.prevent @drop.prevent="onTlCharDrop($event)">
        <!-- axis -->
        <div class="tl-axis">
          <div class="tl-axis-header">⏱</div>
          <div class="tl-axis-body" :style="{height:totalTlHeight+'px'}">
            <div v-for="m in currentMarkers" :key="m.index" class="tl-marker"
                 :style="{top:markerY(m.index)+'px'}">
              <span class="tl-marker-label">{{m.label}}</span>
              <div class="tl-marker-line"></div>
              <div class="gap-btns">
                <button class="gap-btn" @click.stop="growGap(m.index)" :title="t('Increase gap')">+</button>
                <button class="gap-btn" @click.stop="shrinkGap(m.index)" :title="t('Decrease gap')">−</button>
              </div>
            </div>
          </div>
        </div>

        <!-- columns -->
        <div v-for="col in filteredOrderColumns" :key="'col'+(col.characterId||'general')" class="tl-col" :style="tlColStyle">
          <div class="tl-col-header" :style="{background:charColorLight(col.characterId),borderBottomColor:charColor(col.characterId)}"
               draggable="true" @dragstart="onColDragStart(col,$event)" @dragover="onColDragOver(col,$event)"
               @drop="onColDrop(col,$event)" @dragend="onColDragEnd">
            {{charName(col.characterId)}}
            <button class="icon-btn sm" @click="removeColumn(col)" title="Remove column">✕</button>
          </div>
          <div class="tl-col-body" :style="{height:totalTlHeight+'px'}" @dblclick="onTlColDblClick(col,$event)">
            <!-- marker lines -->
            <div v-for="m in currentMarkers" :key="'ml'+m.index" class="tl-col-marker-line"
                 :style="{top:markerY(m.index)+'px'}"></div>
            <!-- events -->
            <div v-for="evt in col.events" :key="evt.id" class="tl-evt"
                 :class="{'tl-evt-editing':editingEvtId===evt.id}"
                 :style="editingEvtId===evt.id
                   ? {top:evt.yPos+'px',minHeight:evt.height+'px',height:'auto',borderLeftColor:charColor(col.characterId),overflow:'visible',zIndex:10}
                   : {top:evt.yPos+'px',height:evt.height+'px',borderLeftColor:charColor(col.characterId)}"
                 @mousedown="editingEvtId===evt.id?null:onEvtDrag(evt,$event)" @dblclick.stop="editingEvtId=evt.id">
              <!-- Normal view (not editing) -->
              <template v-if="editingEvtId!==evt.id">
                <div class="tl-evt-text">{{evt.description||t('(double-click to edit)')}}</div>
                <div class="tl-evt-bottom">
                  <div v-if="evt.locationId" class="tl-evt-loc-badge" @click.stop="goToLocation(evt.locationId)" @mousedown.stop title="Go to location">
                    📍 {{locName(evt.locationId)}}
                  </div>
                  <div class="tl-evt-time">{{evt.time}}</div>
                </div>
                <!-- hover tooltip -->
                <div v-if="evt.description" class="tl-evt-tooltip">{{evt.description}}<span v-if="evt.locationId" class="tl-evt-tooltip-loc">📍 {{locName(evt.locationId)}}</span></div>
              </template>
              <!-- Editing view -->
              <template v-else>
                <textarea class="tl-evt-edit" v-model="evt.description" @input="mark()" @mousedown.stop :placeholder="t('Describe event…')"></textarea>
                <div class="tl-evt-edit-row" @mousedown.stop>
                  <select class="tl-evt-loc-sel" v-model="evt.locationId" @change="mark()">
                    <option :value="null">📍 {{t('No location')}}</option>
                    <option v-for="loc in book.locations" :key="loc.id" :value="loc.id">📍 {{loc.name}}</option>
                  </select>
                  <button class="tl-evt-done-btn" @click.stop="editingEvtId=null">✓</button>
                </div>
                <div class="tl-evt-edit-bottom">
                  <div class="tl-evt-time">{{evt.time}}</div>
                </div>
              </template>
              <div class="tl-evt-resize" @mousedown="onEvtResize(evt,$event)" title="Drag to resize"></div>
              <button class="tl-evt-del" @click.stop="removeEvt(col,evt)">✕</button>
            </div>
          </div>
        </div>

        <!-- empty hint -->
        <div v-if="!currentOrder.characterColumns.length" class="tl-empty-hint">
          <p>{{t('Drag characters from above or add a General column, then double-click to place events.')}}</p>
        </div>
      </div>
    </div>
  </section>

  <!-- ═══════════════ QUESTIONS ═══════════════ -->
  <section v-if="activeTab==='Questions'">
    <div class="tab-header"><h3>{{t('Questions')}}</h3>
      <div class="tab-actions"><button class="save-btn" @click="saveBook">💾 {{t('Save')}}</button></div>
    </div>
    <div class="form-card" style="max-width:520px">
      <div class="form-row"><input v-model="newQText" :placeholder="t('Type a question…')" @keyup.enter="addQuestion"/>
        <button @click="addQuestion">+ {{t('Add')}}</button></div>
    </div>
    <div v-if="book.questions.length" class="q-grid">
      <div v-for="q in book.questions" :key="q.id" class="q-card" :class="qClass(q)">
        <div class="q-top">
          <h4>{{q.text}}</h4>
          <button class="icon-btn" @click="removeQuestion(q)" :title="t('Delete')">🗑</button>
        </div>
        <textarea v-model="q.answer" @input="mark()" :placeholder="t('Type your answer…')" rows="3"></textarea>
        <label class="q-check"><input type="checkbox" v-model="q.answered" @change="mark()"/> {{t('Answered')}}</label>
      </div>
    </div>
    <div v-else class="empty-state"><p>{{t('No questions yet.')}}</p></div>
  </section>

  <!-- ═══════════════ LOCATIONS ═══════════════ -->
  <section v-if="activeTab==='Locations'">
    <div class="tab-header"><h3>{{t('Locations')}}</h3>
      <div class="tab-actions">
        <button @click="openImportModal('locations')">📥 {{t('Import Locations')}}</button>
        <button @click="newLoc.open=true">+ {{t('Add Location')}}</button>
        <button class="save-btn" @click="saveBook">💾 {{t('Save')}}</button>
      </div>
    </div>

    <div v-if="newLoc.open" class="form-card">
      <h4>{{t('New Location')}}</h4>
      <div class="fg2">
        <div class="field"><label>{{t('Name')}}</label><input v-model="newLoc.name" :placeholder="t('Castle Grounds')"/></div>
        <div class="field"><label>{{t('Description')}}</label><input v-model="newLoc.description" :placeholder="t('Optional description')"/></div>
      </div>
      <div class="fg3">
        <div class="field"><label>{{t('Width')}}</label><input type="number" v-model.number="newLoc.width" min="1"/></div>
        <div class="field"><label>{{t('Height')}}</label><input type="number" v-model.number="newLoc.height" min="1"/></div>
        <div class="field"><label>{{t('Unit')}}</label>
          <select v-model="newLoc.unit"><option>m</option><option>km</option><option>ft</option><option>mi</option><option>units</option></select>
        </div>
      </div>
      <div class="form-actions"><button class="primary" @click="addLocation">{{t('Create')}}</button><button @click="newLoc.open=false">{{t('Cancel')}}</button></div>
    </div>

    <div v-if="!currentLoc" class="loc-list">
      <div v-for="loc in book.locations" :key="loc.id" class="loc-item">
        <div><strong>{{loc.name}}</strong> <span class="small-note">{{loc.width}}×{{loc.height}} {{loc.unit}} · {{loc.objects.length}} {{t('objects')}}</span></div>
        <div class="loc-item-actions"><button @click="openLocation(loc.id)">{{t('Open')}}</button><button class="icon-btn" @click="deleteLocation(loc.id)">🗑</button></div>
      </div>
      <div v-if="!book.locations.length" class="empty-state"><p>{{t('No locations yet.')}}</p></div>
    </div>

    <div v-if="currentLoc" class="loc-editor">
      <div class="loc-ed-toolbar">
        <button @click="closeLocation">← {{t('Back')}}</button>
        <strong>{{currentLoc.name}}</strong>
        <span class="small-note">{{currentLoc.width}}×{{currentLoc.height}} {{currentLoc.unit}}</span>
      </div>

      <div class="draw-tools">
        <button v-for="dt in ['select','rectangle','ellipse','circle','tree','house','castle','car','bed','table','door','shop','building','fountain','lake','road','sand','garden']"
                :key="dt" :class="{active:drawTool===dt}" @click="selectDrawTool(dt)" class="dt-btn">
          <span class="dt-icon">{{
            dt==='select'?'🔘':dt==='rectangle'?'▬':dt==='ellipse'?'⬭':dt==='circle'?'●':
            dt==='tree'?'🌳':dt==='house'?'🏠':dt==='castle'?'🏰':dt==='car'?'🚗':
            dt==='bed'?'🛏️':dt==='table'?'▣':dt==='door'?'🚪':
            dt==='shop'?'🏪':dt==='building'?'🏢':dt==='fountain'?'⛲':
            dt==='lake'?'💧':dt==='road'?'🛣️':dt==='sand'?'🏖️':dt==='garden'?'🌿':''
          }}</span>
          <span class="dt-label">{{t(dt)}}</span>
        </button>
      </div>

      <div class="loc-canvas-wrap">
        <div v-if="selectedObj" class="prop-panel">
          <h4>{{t('Properties')}}</h4>
          <div class="field"><label>{{t('Name')}}</label><input v-model="selectedObj.name" @input="mark()"/></div>
          <div class="field"><label>{{t('Fill Color')}}</label><input type="color" :value="selectedObj.color&&selectedObj.color.startsWith('rgba')?'#3498db':selectedObj.color" @input="selectedObj.color=$event.target.value;mark()"/></div>
          <div class="field"><label>{{t('Stroke')}}</label><input type="color" v-model="selectedObj.stroke" @input="mark()"/></div>
          <div v-if="selectedObj.points&&selectedObj.points.length" class="field">
            <label>{{t('Stroke Width')}}</label><input type="number" v-model.number="selectedObj.strokeWidth" min="1" max="40" @input="mark()"/>
          </div>
          <div v-if="!selectedObj.points||!selectedObj.points.length" class="fg2">
            <div class="field"><label>{{t('Width')}}</label><input type="number" v-model.number="selectedObj.width" min="1" @input="mark()"/></div>
            <div class="field"><label>{{t('Height')}}</label><input type="number" v-model.number="selectedObj.height" min="1" @input="mark()"/></div>
          </div>
          <div v-if="ALL_ICONS.includes(selectedObj.type)" class="field">
            <label>{{t('Scale')}}</label><input type="number" v-model.number="selectedObj.scale" min="0.2" max="5" step="0.1" @input="mark()"/>
          </div>
          <button class="danger" @click="deleteSelectedObj" style="margin-top:8px">{{t('Delete Object')}}</button>
        </div>

        <svg ref="locSvg" class="loc-svg" :width="locCanvasW()" :height="locCanvasH()"
             @mousedown="onLocMD" @mousemove="onLocMM" @mouseup="onLocMU" @click="onLocClick" @dblclick="onLocDblClick">
          <defs>
            <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
              <path d="M 40 0 L 0 0 0 40" fill="none" stroke="#e0dcd4" stroke-width="0.5"/>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill="url(#grid)"/>

          <!-- X-axis -->
          <g class="loc-axis">
            <rect :x="0" :y="locCanvasH()-24" :width="locCanvasW()" height="24" fill="rgba(255,255,255,0.88)"/>
            <line x1="0" :y1="locCanvasH()-24" :x2="locCanvasW()" :y2="locCanvasH()-24" stroke="#bbb" stroke-width="1"/>
            <template v-for="tick in locXTicks" :key="'xt'+tick.value">
              <line :x1="tick.px" :y1="locCanvasH()-24" :x2="tick.px" :y2="locCanvasH()-18" stroke="#999" stroke-width="1"/>
              <text :x="tick.px" :y="locCanvasH()-5" text-anchor="middle" font-size="10" fill="#777">{{tick.label}}</text>
            </template>
            <text :x="locCanvasW()-4" :y="locCanvasH()-5" text-anchor="end" font-size="9" fill="#aaa" font-style="italic">{{currentLoc.unit}}</text>
          </g>
          <!-- Y-axis -->
          <g class="loc-axis">
            <rect x="0" y="0" width="34" :height="locCanvasH()-24" fill="rgba(255,255,255,0.88)"/>
            <line x1="34" y1="0" x2="34" :y2="locCanvasH()-24" stroke="#bbb" stroke-width="1"/>
            <template v-for="tick in locYTicks" :key="'yt'+tick.value">
              <line x1="28" :y1="tick.px" x2="34" :y2="tick.px" stroke="#999" stroke-width="1"/>
              <text x="26" :y="tick.px+3" text-anchor="end" font-size="10" fill="#777">{{tick.label}}</text>
            </template>
          </g>

          <!-- rendered objects -->
          <template v-for="obj in currentLoc.objects" :key="obj.id">
            <rect v-if="obj.type==='rectangle'"
                  :x="obj.x-obj.width/2" :y="obj.y-obj.height/2" :width="obj.width" :height="obj.height"
                  :fill="obj.color" :stroke="obj.stroke" :stroke-width="obj.strokeWidth"
                  :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)"/>
            <ellipse v-if="obj.type==='ellipse'"
                     :cx="obj.x" :cy="obj.y" :rx="obj.width/2" :ry="obj.height/2"
                     :fill="obj.color" :stroke="obj.stroke" :stroke-width="obj.strokeWidth"
                     :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)"/>
            <circle v-if="obj.type==='circle'"
                    :cx="obj.x" :cy="obj.y" :r="obj.width/2"
                    :fill="obj.color" :stroke="obj.stroke" :stroke-width="obj.strokeWidth"
                    :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)"/>
            <!-- tree -->
            <g v-if="obj.type==='tree'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <polygon points="0,-25 18,10 -18,10" :fill="obj.color"/>
              <rect x="-4" y="10" width="8" height="10" fill="#8B4513"/>
            </g>
            <!-- house -->
            <g v-if="obj.type==='house'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-18" y="-5" width="36" height="28" :fill="obj.color"/>
              <polygon points="-22,-5 0,-25 22,-5" :fill="obj.stroke"/>
              <rect x="-5" y="5" width="10" height="18" fill="#f39c12"/>
            </g>
            <!-- castle -->
            <g v-if="obj.type==='castle'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-24" y="-8" width="48" height="32" :fill="obj.color"/>
              <rect x="-24" y="-18" width="10" height="10" :fill="obj.color"/>
              <rect x="-5" y="-18" width="10" height="10" :fill="obj.color"/>
              <rect x="14" y="-18" width="10" height="10" :fill="obj.color"/>
              <rect x="-4" y="6" width="8" height="18" fill="#555"/>
            </g>
            <!-- car -->
            <g v-if="obj.type==='car'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-22" y="-6" width="44" height="16" rx="3" :fill="obj.color"/>
              <rect x="-14" y="-14" width="28" height="10" rx="3" :fill="obj.color" opacity="0.75"/>
              <circle cx="-13" cy="12" r="5" fill="#2c3e50"/><circle cx="13" cy="12" r="5" fill="#2c3e50"/>
            </g>
            <!-- bed -->
            <g v-if="obj.type==='bed'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-18" y="-4" width="36" height="16" rx="2" :fill="obj.color"/>
              <rect x="-18" y="-10" width="6" height="22" rx="1" :fill="obj.color" opacity="0.8"/>
              <rect x="12" y="2" width="6" height="10" rx="1" :fill="obj.color" opacity="0.6"/>
              <rect x="-14" y="-2" width="12" height="8" rx="3" fill="#fff" opacity="0.35"/>
            </g>
            <!-- table -->
            <g v-if="obj.type==='table'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-18" y="-4" width="36" height="5" rx="1" :fill="obj.color"/>
              <rect x="-14" y="1" width="3" height="14" :fill="obj.color" opacity="0.7"/>
              <rect x="11" y="1" width="3" height="14" :fill="obj.color" opacity="0.7"/>
            </g>
            <!-- door -->
            <g v-if="obj.type==='door'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-8" y="-16" width="16" height="32" rx="1" :fill="obj.color"/>
              <circle cx="4" cy="2" r="2" fill="#f1c40f"/>
            </g>
            <!-- shop -->
            <g v-if="obj.type==='shop'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-18" y="-4" width="36" height="24" :fill="obj.color"/>
              <polygon points="-20,-4 -20,-12 20,-12 20,-4" fill="#c0392b" opacity="0.5"/>
              <rect x="-3" y="4" width="6" height="16" fill="#8B4513" opacity="0.6"/>
            </g>
            <!-- building -->
            <g v-if="obj.type==='building'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <rect x="-12" y="-22" width="24" height="44" :fill="obj.color"/>
              <rect x="-8" y="-16" width="5" height="5" fill="#f1c40f" opacity="0.6"/>
              <rect x="3" y="-16" width="5" height="5" fill="#f1c40f" opacity="0.6"/>
              <rect x="-8" y="-6" width="5" height="5" fill="#f1c40f" opacity="0.6"/>
              <rect x="3" y="-6" width="5" height="5" fill="#f1c40f" opacity="0.6"/>
              <rect x="-3" y="10" width="6" height="12" fill="#555"/>
            </g>
            <!-- fountain -->
            <g v-if="obj.type==='fountain'" :transform="'translate('+obj.x+','+obj.y+') scale('+(obj.scale||1)+')'"
               :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move">
              <ellipse cx="0" cy="6" rx="16" ry="8" :fill="obj.color" opacity="0.5"/>
              <rect x="-2" y="-10" width="4" height="16" fill="#95a5a6"/>
              <circle cx="0" cy="-12" r="4" fill="rgba(52,152,219,0.5)"/>
            </g>
            <!-- lake / sand / garden (polygon) -->
            <polygon v-if="['lake','sand','garden'].includes(obj.type)&&obj.points&&obj.points.length>=3"
                     :points="polyPoints(obj.points)" :fill="obj.color" :stroke="obj.stroke" :stroke-width="obj.strokeWidth"
                     :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move"/>
            <!-- road (polyline) -->
            <polyline v-if="obj.type==='road'&&obj.points&&obj.points.length>=2"
                      :points="polyPoints(obj.points)" fill="none" :stroke="obj.color" :stroke-width="obj.strokeWidth"
                      stroke-linecap="round" stroke-linejoin="round"
                      :class="{'svg-sel':selectedObjId===obj.id}" @mousedown="onObjMD(obj,$event)" style="cursor:move"/>
            <!-- label -->
            <text v-if="obj.name&&(obj.type!=='road'||obj.points.length)"
                  :x="obj.points&&obj.points.length?obj.points.reduce((a,p)=>a+p[0],0)/obj.points.length:obj.x"
                  :y="(obj.points&&obj.points.length?obj.points.reduce((a,p)=>a+p[1],0)/obj.points.length:obj.y)+(obj.points&&obj.points.length?0:(obj.height||40)/2+14)"
                  text-anchor="middle" font-size="11" fill="#333" stroke="#fff" stroke-width="2.5" paint-order="stroke">{{obj.name}}</text>
          </template>

          <!-- drawing preview: shape -->
          <rect v-if="isDrawingShape&&drawStart&&drawTool==='rectangle'"
                :x="Math.min(drawStart.x,cursorPos.x)" :y="Math.min(drawStart.y,cursorPos.y)"
                :width="Math.abs(cursorPos.x-drawStart.x)" :height="Math.abs(cursorPos.y-drawStart.y)"
                fill="rgba(100,100,200,0.2)" stroke="#667" stroke-dasharray="4"/>
          <ellipse v-if="isDrawingShape&&drawStart&&drawTool==='ellipse'"
                   :cx="(drawStart.x+cursorPos.x)/2" :cy="(drawStart.y+cursorPos.y)/2"
                   :rx="Math.abs(cursorPos.x-drawStart.x)/2" :ry="Math.abs(cursorPos.y-drawStart.y)/2"
                   fill="rgba(100,100,200,0.2)" stroke="#667" stroke-dasharray="4"/>
          <circle v-if="isDrawingShape&&drawStart&&drawTool==='circle'"
                  :cx="(drawStart.x+cursorPos.x)/2" :cy="(drawStart.y+cursorPos.y)/2"
                  :r="Math.max(Math.abs(cursorPos.x-drawStart.x),Math.abs(cursorPos.y-drawStart.y))/2"
                  fill="rgba(100,100,200,0.2)" stroke="#667" stroke-dasharray="4"/>
          <!-- drawing preview: area points -->
          <template v-if="drawingPts.length">
            <polyline :points="polyPoints(drawingPts)" fill="none" stroke="#4a7dff" stroke-width="2" stroke-dasharray="5"/>
            <line v-if="drawingPts.length" :x1="drawingPts[drawingPts.length-1][0]" :y1="drawingPts[drawingPts.length-1][1]"
                  :x2="cursorPos.x" :y2="cursorPos.y" stroke="#4a7dff" stroke-width="1" stroke-dasharray="3"/>
            <circle v-for="(pt,i) in drawingPts" :key="'dp'+i" :cx="pt[0]" :cy="pt[1]" r="4" fill="#4a7dff"/>
          </template>
        </svg>
      </div>
    </div>
  </section>

  <!-- ═══════════════ NOTES ═══════════════ -->
  <section v-if="activeTab==='Notes'">
    <div class="tab-header"><h3>{{t('Notes')}}</h3>
      <div class="tab-actions"><button class="save-btn" @click="saveBook">💾 {{t('Save')}}</button></div>
    </div>

    <div class="notes-layout">
      <!-- Topics sidebar -->
      <div class="topics-sidebar">
        <h4>{{t('Topics')}}</h4>
        <div class="topic-list">
          <div v-for="tp in book.topics" :key="tp.id" class="topic-item"
               :class="{active:currentTopicId===tp.id}" @click="currentTopicId=tp.id">
            <span class="topic-name">{{tp.name}}</span>
            <span class="topic-count">{{tp.notes.length}}</span>
            <button class="icon-btn sm" @click.stop="removeTopic(tp)" :title="t('Delete topic')">✕</button>
          </div>
        </div>
        <div class="form-row" style="margin-top:12px">
          <input v-model="newTopicName" :placeholder="t('New topic…')" @keyup.enter="addTopic"/>
          <button @click="addTopic">+</button>
        </div>
      </div>

      <!-- Notes main area -->
      <div v-if="currentTopic" class="notes-main">
        <h4 class="notes-main-title">{{currentTopic.name}}</h4>
        <div class="postit-grid">
          <div v-for="note in currentTopic.notes" :key="note.id" class="postit" :style="{background:note.color}">
            <textarea v-model="note.text" @input="mark()" :placeholder="t('Write a note…')"></textarea>
            <div class="postit-footer">
              <select v-model="note.color" @change="mark()" class="postit-color-sel">
                <option v-for="c in postitColors" :key="c.value" :value="c.value">{{c.label}}</option>
              </select>
              <button class="icon-btn sm" @click="removeNote(note)" :title="t('Delete note')">✕</button>
            </div>
          </div>
          <div class="postit-add" @click="addNote">
            <span>+ {{t('Add Note')}}</span>
          </div>
        </div>
      </div>
      <div v-else class="notes-main notes-empty">
        <p>{{t('Select or create a topic to start adding notes.')}}</p>
      </div>

      <!-- URLs sidebar -->
      <div v-if="currentTopic" class="urls-sidebar">
        <h4>{{t('Links')}}</h4>
        <div class="url-list">
          <div v-for="(url,i) in currentTopic.urlLinks" :key="'u'+i" class="url-item">
            <a :href="url" target="_blank" rel="noopener" class="url-link" :title="url">{{url}}</a>
            <button class="icon-btn sm" @click="removeUrl(i)">✕</button>
          </div>
        </div>
        <div class="form-row" style="margin-top:12px">
          <input v-model="newUrl" placeholder="https://…" @keyup.enter="addUrl"/>
          <button @click="addUrl">+</button>
        </div>
      </div>
    </div>
  </section>

  </main>
</div>

<!-- MODALS -->
<div v-if="linkModal.open" class="modal-overlay" @click.self="cancelLinkModal">
  <div class="modal-card">
    <h4>{{t('Create Relation')}}</h4>
    <p class="modal-chars">
      <span :style="{color:charColor(linkModal.c1)}">{{charName(linkModal.c1)}}</span>
      <span class="modal-arrow">↔</span>
      <span :style="{color:charColor(linkModal.c2)}">{{charName(linkModal.c2)}}</span>
    </p>
    <div class="field"><label>{{t('Relation type')}}</label>
      <input v-model="linkModal.type" :placeholder="t('e.g. friends, rivals')" @keyup.enter="confirmLink" ref="linkTypeInput"/>
    </div>
    <div class="modal-actions"><button class="primary" @click="confirmLink">{{t('Create Link')}}</button><button @click="cancelLinkModal">{{t('Cancel')}}</button></div>
  </div>
</div>

<div v-if="showUnsavedDialog" class="modal-overlay" @click.self="unsavedCancel">
  <div class="modal-card">
    <h4>{{t('Unsaved Changes')}}</h4>
    <p>{{t('You have unsaved changes. What would you like to do?')}}</p>
    <div class="modal-actions">
      <button class="primary" @click="unsavedSave">{{t('Save & Continue')}}</button>
      <button class="danger" @click="unsavedDiscard">{{t('Discard')}}</button>
      <button @click="unsavedCancel">{{t('Cancel')}}</button>
    </div>
  </div>
</div>

<!-- Import modal -->
<div v-if="importModal.open" class="modal-overlay" @click.self="importModal.open=false">
  <div class="modal-card import-modal">
    <h4>{{importModal.type==='characters' ? t('Import Characters') : t('Import Locations')}}</h4>
    <div class="field">
      <label>{{t('Source book')}}</label>
      <select v-model="importModal.bookTitle" @change="importModal.selectedIds=[]">
        <option value="" disabled>{{t('Select a book…')}}</option>
        <template v-for="sb in savedBooks" :key="sb.title">
          <option v-if="sb.title!==book.title" :value="sb.title">{{sb.title}}</option>
        </template>
      </select>
    </div>
    <div v-if="importableItems.length" class="import-items">
      <label v-for="item in importableItems" :key="item.id" class="import-item" :class="{selected:importModal.selectedIds.includes(item.id)}">
        <input type="checkbox" :checked="importModal.selectedIds.includes(item.id)" @change="toggleImportItem(item.id)"/>
        <span>{{item.name}}</span>
      </label>
    </div>
    <div v-else-if="importModal.bookTitle" class="small-note" style="padding:12px 0">{{t('No items to import.')}}</div>
    <div class="modal-actions">
      <button class="primary" @click="confirmImport" :disabled="!importModal.selectedIds.length">{{t('Import')}}</button>
      <button @click="importModal.open=false">{{t('Cancel')}}</button>
    </div>
  </div>
</div>

<div v-if="toast" class="toast">{{toast}}</div>
</div>
  `
}).mount('#app');
