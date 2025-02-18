/**
  Copyright (C) 2012-2018 by Autodesk, Inc.
  All rights reserved.

  Heidenhain post processor configuration.

  $Revision: 42238 391e76d643f749ec7b6a8894df857cc3c243519c $
  $Date: 2019-01-28 07:54:34 $
  
  FORKID {8CD295BC-DAB4-4C5E-BAC6-1236326FB6A9}
*/

description = "DMG MORI DMU 50 ECOLINE";
vendor = "DMG MORI";
vendorUrl = "http://en.dmgmori.com";
legal = "Copyright (C) 2012-2018 by Autodesk, Inc.";
certificationLevel = 2;
minimumRevision = 24000;

longDescription = "Post for DMG MORI DMU 50 with Heidenhain control.";

extension = "h";
if (getCodePage() == 932) { // shift-jis is not supported
  setCodePage("ascii");
} else {
  setCodePage("ansi"); // setCodePage("utf-8");
}

capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(5400); // 15 revolutions
allowHelicalMoves = true;
allowedCircularPlanes = undefined; // allow any circular motion



// user-defined properties
properties = {
  writeMachine: true, // write machine
  writeTools: true, // writes the tools
  usePlane: true, // uses PLANE if true and otherwise cycle 19
  useFunctionTCPM: false, // use FUNCTION TCPM instead of M128/M129
  preloadTool: true, // preloads next tool on tool change if any
  expandCycles: true, // expands unhandled cycles
  smoothingTolerance: 0, // smoothing tolerance (0 ~ disabled)
  optionalStop: true, // optional stop
  structureComments: true, // show structure comments
  useM92: false, // use M92 instead of M91
  useParametricFeed: false, // specifies that feed should be output using Q values
  showNotes: false, // specifies that operation notes should be output.
  preferTilt: "1" // -1: negative, 0:dont care, 1: positive
};

// user-defined property definitions
propertyDefinitions = {
  writeMachine: {title:"Write machine", description:"Output the machine settings in the header of the code.", group:0, type:"boolean"},
  writeTools: {title:"Write tool list", description:"Output a tool list in the header of the code.", group:0, type:"boolean"},
  usePlane: {title:"Use plane", description:"If true, planes are used instead of cycle 19.", type:"boolean"},
  useFunctionTCPM: {title:"Use function TCPM", description:"Specifies whether to use Function TCPM instead of M128/M129.", type:"boolean"},
  preloadTool: {title:"Preload tool", description:"Preloads the next tool at a tool change (if any).", group:1, type:"boolean"},
  expandCycles: {title:"Expand cycles", description:"If enabled, unhandled cycles are expanded.", type:"boolean"},
  smoothingTolerance: {title:"Smoothing tolerance", description:"Smoothing tolerance (-1 for disabled).", type:"number"},
  optionalStop: {title:"Optional stop", description:"Outputs optional stop code during when necessary in the code.", type:"boolean"},
  structureComments: {title:"Structure comments", description:"Shows structure comments.", type:"boolean"},
  useM92: {title:"Use M92", description:"If enabled, M91 is used instead of M91.", type:"boolean"},
  useParametricFeed:  {title:"Parametric feed", description:"Specifies the feed value that should be output using a Q value.", type:"boolean"},
  showNotes: {title:"Show notes", description:"Writes operation notes as comments in the outputted code.", type:"boolean"},
  preferTilt: {title:"Prefer tilt", description:"Specifies which tilt direction is preferred.", type:"enum", values:[{id:"-1", title:"Negative"}, {id:"0", title:"Either"}, {id:"1", title:"Positive"}]} // TAG: Mac
};

// fixed settings
var closestABC = false; // choose closest machine angles
var forceMultiAxisIndexing = false; // force multi-axis indexing for 3D programs
var useCycl247 = true; // use CYCL 247 for work offset
var useCycl205 = false; // use CYCL 205 for universal pecking


var WARNING_WORK_OFFSET = 0;

// collected state
var blockNumber = 0;
var activeMovements; // do not use by default
var workOffsetLabels = {};
var nextLabel = 1;
var optionalSection = false;

var spindleAxisTable = new Table(["X", "Y", "Z"], {force:true});

var radiusCompensationTable = new Table(
  [" R0", " RL", " RR"],
  {initial:RADIUS_COMPENSATION_OFF},
  "Invalid radius compensation"
);

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceSign:true});
var abcFormat = createFormat({decimals:3, forceSign:true, scale:DEG});
// var cFormat = createFormat({decimals:3, forceSign:true, scale:DEG, cyclicLimit:2*Math.PI, cyclicSign:1});
var feedFormat = createFormat({decimals:(unit == MM ? 0 : 2), scale:(unit == MM ? 1 : 10)});
var txyzFormat = createFormat({decimals:(unit == MM ? 7 : 8), forceSign:true});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:3});
var paFormat = createFormat({decimals:3, forceSign:true, scale:DEG});
var angleFormat = createFormat({decimals:0, scale:DEG});
var pitchFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceSign:true});
var ratioFormat = createFormat({decimals:3});
var mFormat = createFormat({prefix:"M", decimals:0});

// presentation formats
var spatialFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var taperFormat = angleFormat; // share format

var xOutput = createVariable({prefix:" X"}, xyzFormat);
var yOutput = createVariable({prefix:" Y"}, xyzFormat);
var zOutput = createVariable({prefix:" Z"}, xyzFormat);
var txOutput = createVariable({prefix:" TX", force:true}, txyzFormat);
var tyOutput = createVariable({prefix:" TY", force:true}, txyzFormat);
var tzOutput = createVariable({prefix:" TZ", force:true}, txyzFormat);
var aOutput = createVariable({prefix:" A"}, abcFormat);
var bOutput = createVariable({prefix:" B"}, abcFormat);
var cOutput = createVariable({prefix:" C"}, abcFormat);
var feedOutput = createVariable({prefix:" F"}, feedFormat);

/** Force output of X, Y, and Z. */
function forceXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

/** Force output of A, B, and C. */
function forceABC() {
  aOutput.reset();
  bOutput.reset();
  cOutput.reset();
}

/**
  Writes the specified block.
*/
function writeBlock(block) {
  if (optionalSection) {
    writeln("/" + blockNumber + SP + block);
  } else {
    writeln(blockNumber + SP + block);
  }
  ++blockNumber;
}

/**
  Writes the specified block as optional.
*/
function writeOptionalBlock(block) {
  writeln("/" + blockNumber + SP + block);
  ++blockNumber;
}

/** Output a comment. */
function writeComment(text) {
  if (isTextSupported(text)) {
    writeln(blockNumber + SP + "; " + text); // some controls may require a block number
    ++blockNumber;
  }
}

/** Adds a structure comment. */
function writeStructureComment(text) {
  if (properties.structureComments) {
    if (isTextSupported(text)) {
      writeln(blockNumber + SP + "* - " + text); // never make optional
      ++blockNumber;
    }
  }
}

/** Writes a separator. */
function writeSeparator() {
  writeComment("-------------------------------------");
}

/** Writes the specified text through the data interface. */
function printData(text) {
  if (isTextSupported(text)) {
    writeln("FN15: PRINT " + text);
  }
}

function onOpen() {

  properties.preferTilt = parseInt(properties.preferTilt); // TAG: Mac NOTE: This line usually needs to be added to the post in this location.

  if (true) {
    var bAxis = createAxis({coordinate:1, table:true, axis:[0, 1, 0], range:[-10, 120.0001], preference:1});
    var cAxis = createAxis({coordinate:2, table:true, axis:[0, 0, 1], range:[0, 360], cyclic:true});
    machineConfiguration = new MachineConfiguration(bAxis, cAxis);
    machineConfiguration.setRetractPlane(-1);
    setMachineConfiguration(machineConfiguration);
    optimizeMachineAngles2(0); // using M128 mode
  }

  if (!machineConfiguration.isMachineCoordinate(0)) {
    aOutput.disable();
  }
  if (!machineConfiguration.isMachineCoordinate(1)) {
    bOutput.disable();
  }
  if (!machineConfiguration.isMachineCoordinate(2)) {
    cOutput.disable();
  }
  
  writeBlock(
    "BEGIN PGM" + (programName ? (SP + programName) : "") + ((unit == MM) ? " MM" : " INCH")
  );
  if (programComment) {
    writeComment(programComment);
  }

  { // stock - workpiece
    var workpiece = getWorkpiece();
    var delta = Vector.diff(workpiece.upper, workpiece.lower);
    if (delta.isNonZero()) {
      writeBlock("BLK FORM 0.1 Z X" + xyzFormat.format(workpiece.lower.x) + " Y" + xyzFormat.format(workpiece.lower.y) + " Z" + xyzFormat.format(workpiece.lower.z));
      writeBlock("BLK FORM 0.2 X" + xyzFormat.format(workpiece.upper.x) + " Y" + xyzFormat.format(workpiece.upper.y) + " Z" + xyzFormat.format(workpiece.upper.z));
    }
  }

  // dump machine configuration
  var vendor = machineConfiguration.getVendor();
  var model = machineConfiguration.getModel();
  var description = machineConfiguration.getDescription();

  if (properties.writeMachine && (vendor || model || description)) {
    writeSeparator();
    writeComment(localize("Machine"));
    if (vendor) {
      writeComment("  " + localize("vendor") + ": " + vendor);
    }
    if (model) {
      writeComment("  " + localize("model") + ": " + model);
    }
    if (description) {
      writeComment("  " + localize("description") + ": "  + description);
    }
    writeSeparator();
    writeComment("");
  }

  // dump tool information
  if (properties.writeTools) {
    var tools = getToolTable();
    if (tools.getNumberOfTools() > 0) {
      var zRanges = {};
      if (is3D()) {
        var numberOfSections = getNumberOfSections();
        for (var i = 0; i < numberOfSections; ++i) {
          var section = getSection(i);
          var zRange = section.getGlobalZRange();
          var tool = section.getTool();
          if (zRanges[tool.number]) {
            zRanges[tool.number].expandToRange(zRange);
          } else {
            zRanges[tool.number] = zRange;
          }
        }
      }

      writeSeparator();
      writeComment(localize("Tools"));
      for (var i = 0; i < tools.getNumberOfTools(); ++i) {
        var tool = tools.getTool(i);
        var comment = "  #" + tool.number + " " +
          localize("D") + "=" + spatialFormat.format(tool.diameter) +
          conditional(tool.cornerRadius > 0, " " + localize("CR") + "=" + spatialFormat.format(tool.cornerRadius)) +
          conditional((tool.taperAngle > 0) && (tool.taperAngle < Math.PI), " " + localize("TAPER") + "=" + taperFormat.format(tool.taperAngle) + localize("deg"));
          // conditional(tool.tipAngle > 0, " " + localize("TIP:") + "=" + taperFormat.format(tool.tipAngle) + localize("deg"));
        if (zRanges[tool.number]) {
          comment += " - " + localize("ZMIN") + "=" + xyzFormat.format(zRanges[tool.number].getMinimum());
          comment += " - " + localize("ZMAX") + "=" + xyzFormat.format(zRanges[tool.number].getMaximum());
        }
        comment += " - " + getToolTypeName(tool.type);
        writeComment(comment);
        if (tool.comment) {
          writeComment("    " + tool.comment);
        }
        if (tool.vendor) {
          writeComment("    " + tool.vendor);
        }
        if (tool.productId) {
          writeComment("    " + tool.productId);
        }
      }
      writeSeparator();
      writeComment("");
    }
  }

  if (machineConfiguration.isMultiAxisConfiguration()) {
    if (properties.useFunctionTCPM) {
      writeBlock("FUNCTION RESET TCPM");
    } else {
      writeBlock(mFormat.format(129));
    }
  }
}

function onComment(message) {
  writeComment(message);
}

function invalidateXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

function forceFeed() {
  currentFeedId = undefined;
  feedOutput.reset();
}

/**
  Invalidates the current position and feedrate. Invoke this function to
  force X, Y, Z, A, B, C, and F in the following block.
*/
function invalidate() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
  aOutput.reset();
  bOutput.reset();
  cOutput.reset();
  forceFeed();
}

var currentTolerance = undefined;

function setTolerance(tolerance) {
  if (tolerance == currentTolerance) {
    return;
  }
  currentTolerance = tolerance;

  if (tolerance > 0) {
    writeBlock("CYCL DEF 32.0 " + localize("TOLERANCE"));
    writeBlock("CYCL DEF 32.1 T" + xyzFormat.format(tolerance));
    if (machineConfiguration.isMultiAxisConfiguration()) {
      writeBlock("CYCL DEF 32.2 HSC-MODE:0 TA0.05"); // required for 5-axis support
    }
  } else {
    writeBlock("CYCL DEF 32.0 " + localize("TOLERANCE")); // cancel tolerance
    writeBlock("CYCL DEF 32.1");
  }
}

function getSEQ() {
  var SEQ = "";
  switch (properties.preferTilt) {
  case -1:
    SEQ = " SEQ-";
    break;
  case 0:
    break;
  case 1:
    SEQ = " SEQ+";
    break;
  default:
    error(localize("Invalid tilt preference."));
  }
  return SEQ;
}

var currentWorkPlaneABC = undefined;
var currentWorkPlaneABCTurned = false;

function forceWorkPlane() {
  currentWorkPlaneABC = undefined;
}

function setWorkPlane(abc, turn) {
  if (!forceMultiAxisIndexing && is3D() && !machineConfiguration.isMultiAxisConfiguration()) {
    return; // ignore
  }

  if (!((currentWorkPlaneABC == undefined) ||
        abcFormat.areDifferent(abc.x, currentWorkPlaneABC.x) ||
        abcFormat.areDifferent(abc.y, currentWorkPlaneABC.y) ||
        abcFormat.areDifferent(abc.z, currentWorkPlaneABC.z) ||
        (!currentWorkPlaneABCTurned && turn))) {
    return; // no change
  }
  currentWorkPlaneABC = abc;
  currentWorkPlaneABCTurned = turn;

  if (turn) {
    onCommand(COMMAND_UNLOCK_MULTI_AXIS);
  }

  if (properties.usePlane) {
    var TURN = turn ? " TURN FMAX" : " STAY"; // alternatively slow down with F9999
    if (abc.isNonZero()) {
      writeBlock(
        "PLANE SPATIAL SPA" + abcFormat.format(abc.x) + " SPB" + abcFormat.format(abc.y) + " SPC" + abcFormat.format(abc.z) + TURN + getSEQ()
      );
      /*
      var W = currentSection.workPlane; // map to global frame
      writeBlock(
        "PLANE VECTOR" +
        " BX" + txyzFormat.format(W.right.x) + " BY" + txyzFormat.format(W.right.y) + " BZ" + txyzFormat.format(W.right.z) +
        " NX" + txyzFormat.format(W.forward.x) + " NY" + txyzFormat.format(W.forward.y) + " NZ" + txyzFormat.format(W.forward.z) + TURN + getSEQ()
      );
      */
    } else {
      writeBlock("PLANE RESET" + TURN);
    }
  } else {
    writeBlock("CYCL DEF 19.0 " + localize("WORKING PLANE"));
    if (machineConfiguration.isMultiAxisConfiguration()) {
      writeBlock(
        "CYCL DEF 19.1" +
        conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x)) +
        conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y)) +
        conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
      );
    } else {
      writeBlock("CYCL DEF 19.1 A" + abcFormat.format(abc.x) + " B" + abcFormat.format(abc.y) + " C" + abcFormat.format(abc.z));
    }
    if (turn) {
      if (machineConfiguration.isMultiAxisConfiguration()) {
        writeBlock(
          "L" +
          (machineConfiguration.isMachineCoordinate(0) ? " A+Q120" : "") +
          (machineConfiguration.isMachineCoordinate(1) ? " B+Q121" : "") +
          (machineConfiguration.isMachineCoordinate(2) ? " C+Q122" : "") +
          " R0 FMAX"
        );
      }
    }
  }
}

var currentMachineABC;

function getWorkPlaneMachineABC(workPlane) {
  var W = workPlane; // map to global frame

  var abc = machineConfiguration.getABC(W);
  if (closestABC) {
    if (currentMachineABC) {
      abc = machineConfiguration.remapToABC(abc, currentMachineABC);
    } else {
      abc = machineConfiguration.getPreferredABC(abc);
    }
  } else {
    abc = machineConfiguration.getPreferredABC(abc);
  }
  
  try {
    abc = machineConfiguration.remapABC(abc);
    currentMachineABC = abc;
  } catch (e) {
    error(
      localize("Machine angles not supported") + ":"
      + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
      + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
      + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
    );
  }
  
  var direction = machineConfiguration.getDirection(abc);
  if (!isSameDirection(direction, W.forward)) {
    error(localize("Orientation not supported."));
  }
  
  if (!machineConfiguration.isABCSupported(abc)) {
    error(
      localize("Work plane is not supported") + ":"
      + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
      + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
      + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
    );
  }
  
  var tcp = false; // keep false for CYCL 19
  if (tcp) {
    setRotation(W); // TCP mode
  } else {
    var O = machineConfiguration.getOrientation(abc);
    var R = machineConfiguration.getRemainingOrientation(abc, W);
    setRotation(R);
  }
  
  return abc;
}

function FeedContext(id, description, feed) {
  this.id = id;
  this.description = description;
  this.feed = feed;
}

/** Maps the specified feed value to Q feed or formatted feed. */
function getFeed(f) {
  if (activeMovements) {
    var feedContext = activeMovements[movement];
    if (feedContext != undefined) {
      if (!feedFormat.areDifferent(feedContext.feed, f)) {
        if (feedContext.id == currentFeedId) {
          return ""; // nothing has changed
        }
        forceFeed();
        currentFeedId = feedContext.id;
        return " FQ" + (50 + feedContext.id);
      }
    }
    currentFeedId = undefined; // force Q feed next time
  }
  return feedOutput.format(f); // use feed value
}

function initializeActiveFeeds() {
  activeMovements = new Array();
  var movements = currentSection.getMovements();
  
  var id = 0;
  var activeFeeds = new Array();
  if (hasParameter("operation:tool_feedCutting")) {
    if (movements & ((1 << MOVEMENT_CUTTING) | (1 << MOVEMENT_LINK_TRANSITION) | (1 << MOVEMENT_EXTENDED))) {
      var feedContext = new FeedContext(id, localize("Cutting"), getParameter("operation:tool_feedCutting"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_CUTTING] = feedContext;
      activeMovements[MOVEMENT_LINK_TRANSITION] = feedContext;
      activeMovements[MOVEMENT_EXTENDED] = feedContext;
    }
    ++id;
    if (movements & (1 << MOVEMENT_PREDRILL)) {
      feedContext = new FeedContext(id, localize("Predrilling"), getParameter("operation:tool_feedCutting"));
      activeMovements[MOVEMENT_PREDRILL] = feedContext;
      activeFeeds.push(feedContext);
    }
    ++id;
  }
  
  if (hasParameter("operation:finishFeedrate")) {
    if (movements & (1 << MOVEMENT_FINISH_CUTTING)) {
      var feedContext = new FeedContext(id, localize("Finish"), getParameter("operation:finishFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_FINISH_CUTTING] = feedContext;
    }
    ++id;
  } else if (hasParameter("operation:tool_feedCutting")) {
    if (movements & (1 << MOVEMENT_FINISH_CUTTING)) {
      var feedContext = new FeedContext(id, localize("Finish"), getParameter("operation:tool_feedCutting"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_FINISH_CUTTING] = feedContext;
    }
    ++id;
  }
  
  if (hasParameter("operation:tool_feedEntry")) {
    if (movements & (1 << MOVEMENT_LEAD_IN)) {
      var feedContext = new FeedContext(id, localize("Entry"), getParameter("operation:tool_feedEntry"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LEAD_IN] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:tool_feedExit")) {
    if (movements & (1 << MOVEMENT_LEAD_OUT)) {
      var feedContext = new FeedContext(id, localize("Exit"), getParameter("operation:tool_feedExit"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LEAD_OUT] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:noEngagementFeedrate")) {
    if (movements & (1 << MOVEMENT_LINK_DIRECT)) {
      var feedContext = new FeedContext(id, localize("Direct"), getParameter("operation:noEngagementFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LINK_DIRECT] = feedContext;
    }
    ++id;
  } else if (hasParameter("operation:tool_feedCutting") &&
             hasParameter("operation:tool_feedEntry") &&
             hasParameter("operation:tool_feedExit")) {
    if (movements & (1 << MOVEMENT_LINK_DIRECT)) {
      var feedContext = new FeedContext(id, localize("Direct"), Math.max(getParameter("operation:tool_feedCutting"), getParameter("operation:tool_feedEntry"), getParameter("operation:tool_feedExit")));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LINK_DIRECT] = feedContext;
    }
    ++id;
  }
  
  if (hasParameter("operation:reducedFeedrate")) {
    if (movements & (1 << MOVEMENT_REDUCED)) {
      var feedContext = new FeedContext(id, localize("Reduced"), getParameter("operation:reducedFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_REDUCED] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:tool_feedRamp")) {
    if (movements & ((1 << MOVEMENT_RAMP) | (1 << MOVEMENT_RAMP_HELIX) | (1 << MOVEMENT_RAMP_PROFILE) | (1 << MOVEMENT_RAMP_ZIG_ZAG))) {
      var feedContext = new FeedContext(id, localize("Ramping"), getParameter("operation:tool_feedRamp"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_RAMP] = feedContext;
      activeMovements[MOVEMENT_RAMP_HELIX] = feedContext;
      activeMovements[MOVEMENT_RAMP_PROFILE] = feedContext;
      activeMovements[MOVEMENT_RAMP_ZIG_ZAG] = feedContext;
    }
    ++id;
  }
  if (hasParameter("operation:tool_feedPlunge")) {
    if (movements & (1 << MOVEMENT_PLUNGE)) {
      var feedContext = new FeedContext(id, localize("Plunge"), getParameter("operation:tool_feedPlunge"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_PLUNGE] = feedContext;
    }
    ++id;
  }
  if (true) { // high feed
    if (movements & (1 << MOVEMENT_HIGH_FEED)) {
      var feedContext = new FeedContext(id, localize("High Feed"), this.highFeedrate);
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_HIGH_FEED] = feedContext;
    }
    ++id;
  }
  
  for (var i = 0; i < activeFeeds.length; ++i) {
    var feedContext = activeFeeds[i];
    writeBlock("FN0: Q" + (50 + feedContext.id) + "=" + feedFormat.format(feedContext.feed) + " ; " + feedContext.description);
  }
}

function onSection() {
  var forceToolAndRetract = optionalSection && !currentSection.isOptional();
  optionalSection = currentSection.isOptional();
  
  var insertToolCall = forceToolAndRetract || isFirstSection() ||
   (tool.number != getPreviousSection().getTool().number) ||
   (rpmFormat.areDifferent(tool.spindleRPM, getPreviousSection().getTool().spindleRPM)) ||
   (tool.clockwise != getPreviousSection().getTool().clockwise);

  if (insertToolCall) {
    setCoolant(COOLANT_OFF);
  }
  
  var retracted = false; // specifies that the tool has been retracted to the safe plane
  var newWorkOffset = isFirstSection() ||
    (getPreviousSection().workOffset != currentSection.workOffset); // work offset changes
  var newWorkPlane = isFirstSection() ||
    !isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), currentSection.getGlobalInitialToolAxis());
  var fullRetract = insertToolCall || newWorkPlane;

  if (insertToolCall || newWorkOffset || newWorkPlane) {

    if ((forceMultiAxisIndexing || !is3D() || machineConfiguration.isMultiAxisConfiguration()) && newWorkPlane) { // reset working plane
      onCommand(COMMAND_UNLOCK_MULTI_AXIS);
      if (properties.usePlane) {
        writeBlock("PLANE RESET STAY");
      } else {
        writeBlock("CYCL DEF 19.0 " + localize("WORKING PLANE"));
        if (machineConfiguration.isMultiAxisConfiguration()) {
          writeBlock(
            "CYCL DEF 19.1" +
            conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(0))
          );
        } else {
          writeBlock("CYCL DEF 19.1 A" + abcFormat.format(0) + " B" + abcFormat.format(0) + " C" + abcFormat.format(0));
        }
      }
      forceWorkPlane();
    }

    // retract to safe plane
    retracted = true;

    if ((getCurrentSectionId() > 0) &&
        isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), new Vector(0, 0, 1)) ||
        (getCurrentSectionId() == 0) &&
        isSameDirection(currentSection.getGlobalInitialToolAxis(), new Vector(0, 0, 1))) {
      // simple retract
      fullRetract = false;
      writeBlock("L Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));

      if (getCurrentSectionId() == 0) {
        if (machineConfiguration.isMultiAxisConfiguration()) {
          // no need to turn axis aligned with spindle
          writeBlock(
            "L" +
            conditional(machineConfiguration.isMachineCoordinate(0) && !isSameDirection(machineConfiguration.getAxisByCoordinate(0).getAxis(), machineConfiguration.getSpindleAxis()), " A" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(1) && !isSameDirection(machineConfiguration.getAxisByCoordinate(1).getAxis(), machineConfiguration.getSpindleAxis()), " B" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(2) && !isSameDirection(machineConfiguration.getAxisByCoordinate(2).getAxis(), machineConfiguration.getSpindleAxis()), " C" + abcFormat.format(0)) +
            " FMAX"
          );
        }
      }
    } else {
      // full safe retract - for very large parts
      fullRetract = true;
      writeBlock("L Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      // e.g. move to front left position
      // writeBlock("L X" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      // writeBlock("L Y" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));

      var resetTilt = true;
      if (!insertToolCall && (getCurrentSectionId() > 0)) {
        resetTilt = false;
      }

      if (resetTilt) {
        if (machineConfiguration.isMultiAxisConfiguration()) {
          writeBlock(
            "L" +
            conditional(machineConfiguration.isMachineCoordinate(0) && !isSameDirection(machineConfiguration.getAxisByCoordinate(0).getAxis(), machineConfiguration.getSpindleAxis()), " A" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(1) && !isSameDirection(machineConfiguration.getAxisByCoordinate(1).getAxis(), machineConfiguration.getSpindleAxis()), " B" + abcFormat.format(0)) +
            conditional(machineConfiguration.isMachineCoordinate(2) && !isSameDirection(machineConfiguration.getAxisByCoordinate(2).getAxis(), machineConfiguration.getSpindleAxis()), " C" + abcFormat.format(0)) +
            " FMAX"
          );
        }
      }

      if (insertToolCall) {
        // move to tool changer
        // writeBlock("L X" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
        // writeBlock("L Y" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      }
    }
  }

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeStructureComment(comment);
    }
  }

  if (properties.showNotes && hasParameter("notes")) {
    var notes = getParameter("notes");
    if (notes) {
      var lines = String(notes).split("\n");
      var r1 = new RegExp("^[\\s]+", "g");
      var r2 = new RegExp("[\\s]+$", "g");
      for (line in lines) {
        var comment = lines[line].replace(r1, "").replace(r2, "");
        if (comment) {
          writeComment(comment);
        }
      }
    }
  }
  
  if (insertToolCall) {
    forceWorkPlane();
  
    onCommand(COMMAND_STOP_SPINDLE);

    if (!isFirstSection() && properties.optionalStop) {
      onCommand(COMMAND_STOP_CHIP_TRANSPORT);
      onCommand(COMMAND_OPTIONAL_STOP);
    }

    if (!isFirstSection()) {
      onCommand(COMMAND_BREAK_CONTROL);
    }

    if (false) {
      var zRange = currentSection.getGlobalZRange();
      var numberOfSections = getNumberOfSections();
      for (var i = getCurrentSectionId() + 1; i < numberOfSections; ++i) {
        var section = getSection(i);
        var _tool = section.getTool();
        if (_tool.number != tool.number) {
          break;
        }
        zRange.expandToRange(section.getGlobalZRange());
      }

      writeStructureComment("T" + tool.number + "-D" + spatialFormat.format(tool.diameter) + "-CR:" + spatialFormat.format(tool.cornerRadius) + "-ZMIN:" + spatialFormat.format(zRange.getMinimum()) + "-ZMAX:" + spatialFormat.format(zRange.getMaximum()));
    }

    writeBlock(
      "TOOL CALL " + tool.number + SP + spindleAxisTable.lookup(spindleAxis) + " S" + rpmFormat.format(tool.spindleRPM)
    );
    if (tool.comment) {
      writeComment(tool.comment);
    }

    onCommand(COMMAND_TOOL_MEASURE);

    if (properties.preloadTool) {
      var nextTool = getNextTool(tool.number);
      if (nextTool) {
        writeBlock("TOOL DEF " + nextTool.number);
      } else {
        // preload first tool
        var section = getSection(0);
        var firstToolNumber = section.getTool().number;
        if (tool.number != firstToolNumber) {
          writeBlock("TOOL DEF " + firstToolNumber);
        }
      }
    }

    if (isSameDirection(currentSection.getGlobalInitialToolAxis(), new Vector(0, 0, 1))) {
      // simple retract
      writeBlock("L Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      fullRetract = false;
    } else {
      // full safe retract - for very large parts
      fullRetract = true;
      writeBlock("L Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      // writeBlock("L X" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
      // writeBlock("L Y" + xyzFormat.format(?) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
    }

    forceABC();

    onCommand(COMMAND_START_CHIP_TRANSPORT);
    writeBlock(mFormat.format(126)); // shortest path traverse
  }

  onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);

  // wcs
  if (currentSection.workOffset > 0) {
    if (currentSection.workOffset > 9999) {
      error(localize("Work offset out of range."));
      return;
    }
    // datum shift after tool call
    if (useCycl247) {
      if (workOffsetLabels[currentSection.workOffset]) {
        writeBlock("CALL LBL " + workOffsetLabels[currentSection.workOffset] + " ;DATUM");
      } else {
        workOffsetLabels[currentSection.workOffset] = nextLabel;
        writeBlock("LBL " + nextLabel);
        ++nextLabel;
        writeBlock(
          "CYCL DEF 247 " + localize("DATUM SETTING") + " ~" + EOL +
          "  Q339=" + currentSection.workOffset + " ; " + localize("DATUM NUMBER")
        );
        writeBlock("LBL 0");
      }
    } else {
      writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
      writeBlock("CYCL DEF 7.1 #" + currentSection.workOffset);
    }
  } else {
    warningOnce(localize("Work offset has not been specified."), WARNING_WORK_OFFSET);
  }

  if (forceMultiAxisIndexing || !is3D() || machineConfiguration.isMultiAxisConfiguration()) { // use 5-axis indexing for multi-axis mode
    // set working plane after datum shift
    var abc = new Vector(0, 0, 0);
    if (currentSection.isMultiAxis()) {
      forceWorkPlane();
      cancelTransformation();
    } else {
      if (properties.usePlane) {
        if (currentSection.isZOriented()) {
          abc = new Vector(0, 0, -Math.atan2(currentSection.workPlane.right.y, currentSection.workPlane.right.x));
        } else {
          abc = currentSection.workPlane.getTurnAndTilt(0, 2);
        }
        var remaining = Matrix.getXYZRotation(abc).getTransposed().multiply(currentSection.workPlane);
        setRotation(remaining);
      } else {
        if (machineConfiguration.isMultiAxisConfiguration()) {
          abc = getWorkPlaneMachineABC(currentSection.workPlane);
        } else {
          var eulerXYZ = currentSection.workPlane.getTransposed().eulerZYX_R;
          abc = new Vector(-eulerXYZ.x, -eulerXYZ.y, -eulerXYZ.z);
          cancelTransformation();
        }
      }
      setWorkPlane(abc, true); // turn
    }
    
    radiusCompensationTable.lookup(RADIUS_COMPENSATION_OFF);
  } else { // pure 3D
    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);
  }

  if (!currentSection.isMultiAxis()) {
    onCommand(COMMAND_LOCK_MULTI_AXIS);
  }

  invalidate();
  
  if (currentSection.isMultiAxis()) {
    cancelTransformation();
    var abc;
    if (currentSection.isOptimizedForMachine()) {
      abc = currentSection.getInitialToolAxisABC();
      writeBlock(
        "L" +
        aOutput.format(abc.x) +
        bOutput.format(abc.y) +
        cOutput.format(abc.z) +
        " R0 FMAX"
      );
    } else {
      // plane vector set below
    }

    // global position
    var initialPosition = getFramePosition(getGlobalPosition(currentSection.getInitialPosition()));

    // global position
    forceXYZ();
    writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
    writeBlock("CYCL DEF 7.1" + xOutput.format(initialPosition.x));
    writeBlock("CYCL DEF 7.2" + yOutput.format(initialPosition.y));
    writeBlock("CYCL DEF 7.3" + zOutput.format(initialPosition.z));

    if (properties.usePlane) {
      if (machineConfiguration.isMultiAxisConfiguration()) {
        writeBlock(
          "PLANE SPATIAL SPA" + abcFormat.format(abc.x) + " SPB" + abcFormat.format(abc.y) + " SPC" + abcFormat.format(abc.z) + " STAY" + getSEQ()
        );
      } else {
        // x/y axes do not matter as long as we only move to X0 Y0 below
        var forward = currentSection.getGlobalInitialToolAxis();
        var unitZ = new Vector(0, 0, 1);
        var W;
        if (Math.abs(Vector.dot(forward, unitZ)) < 0.5) {
          var imX = Vector.cross(forward, unitZ).getNormalized();
          W = new Matrix(imX, Vector.cross(forward, imX), forward); // make sure this is orthogonal
        } else {
          var imX = Vector.cross(new Vector(0, 1, 0), forward).getNormalized();
          W = new Matrix(imX, Vector.cross(forward, imX), forward); // make sure this is orthogonal
        }
        
        var TURN = true ? " TURN FMAX" : " STAY"; // alternatively slow down with F9999
        writeBlock(
          "PLANE VECTOR" +
          " BX" + txyzFormat.format(W.right.x) + " BY" + txyzFormat.format(W.right.y) + " BZ" + txyzFormat.format(W.right.z) +
          " NX" + txyzFormat.format(W.forward.x) + " NY" + txyzFormat.format(W.forward.y) + " NZ" + txyzFormat.format(W.forward.z) + TURN + getSEQ()
        );
      }
    } else {
      writeBlock("CYCL DEF 19.0 " + localize("WORKING PLANE"));
      if (machineConfiguration.isMultiAxisConfiguration()) {
        writeBlock(
          "CYCL DEF 19.1" +
          conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x)) +
          conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y)) +
          conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
        );
      } else {
        error(localize("CYCL DEF 19 is not allowed without a machine configuration (enable the 'usePlane' setting)."));
        writeBlock("CYCL DEF 19.1 A" + abcFormat.format(abc.x) + " B" + abcFormat.format(abc.y) + " C" + abcFormat.format(abc.z));
      }
    }
    
    writeBlock("L" + xOutput.format(0) + yOutput.format(0) + " R0 FMAX");
    writeBlock("L" + zOutput.format(0) + " R0 FMAX");
    
    writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
    writeBlock("CYCL DEF 7.1 X" + xyzFormat.format(0));
    writeBlock("CYCL DEF 7.2 Y" + xyzFormat.format(0));
    writeBlock("CYCL DEF 7.3 Z" + xyzFormat.format(0));
    if (properties.usePlane) {
      writeBlock("PLANE RESET STAY");
    } else {
      writeBlock("CYCL DEF 19.0 " + localize("WORKING PLANE"));
      if (machineConfiguration.isMultiAxisConfiguration()) {
        writeBlock(
          "CYCL DEF 19.1" +
          conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(0)) +
          conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(0)) +
          conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(0))
        );
      } else {
        writeBlock("CYCL DEF 19.1 A" + abcFormat.format(0) + " B" + abcFormat.format(0) + " C" + abcFormat.format(0));
      }
    }

    if (properties.useFunctionTCPM) {
      writeBlock("FUNCTION TCPM F TCP AXIS POS PATHCTRL AXIS");
    } else {
      writeBlock(mFormat.format(128)); // only after we are at initial position
    }
  } else {
    var initialPosition = getFramePosition(currentSection.getInitialPosition());
    
    if (!retracted) {
      if (getCurrentPosition().z < initialPosition.z) {
        writeBlock("L" + zOutput.format(initialPosition.z) + " FMAX");
      }
    }

    if (!machineConfiguration.isHeadConfiguration()) {
      if (fullRetract) {
        writeBlock("L" + xOutput.format(initialPosition.x) + yOutput.format(initialPosition.y) + " R0 FMAX");
      } else {
        writeBlock("L" + xOutput.format(initialPosition.x) + yOutput.format(initialPosition.y) + " R0 FMAX");
      }
      z = zOutput.format(initialPosition.z);
      if (z) {
        writeBlock("L" + z + " R0 FMAX");
      }
    } else {
      writeBlock("L" + xOutput.format(initialPosition.x) + yOutput.format(initialPosition.y) + zOutput.format(initialPosition.z) + " R0 FMAX");
    }
  }

  // set coolant after we have positioned at Z
  if (insertToolCall) {
    forceCoolant();
  }
  setCoolant(tool.coolant);

  if (forceToolAndRetract) {
    currentTolerance = undefined;
  }
  if (hasParameter("operation-strategy") && (getParameter("operation-strategy") == "drill")) {
    setTolerance(0);
  } else if (hasParameter("operation:tolerance")) {
    setTolerance(Math.max(Math.min(getParameter("operation:tolerance"), properties.smoothingTolerance), 0));
  } else {
    setTolerance(0);
  }
  
  if (properties.useParametricFeed &&
      hasParameter("operation-strategy") &&
      (getParameter("operation-strategy") != "drill") && // legacy
      !(currentSection.hasAnyCycle && currentSection.hasAnyCycle())) {
    if (!insertToolCall &&
        activeMovements &&
        (getCurrentSectionId() > 0) &&
        ((getPreviousSection().getPatternId() == currentSection.getPatternId()) && (currentSection.getPatternId() != 0))) {
      // use the current feeds
    } else {
      initializeActiveFeeds();
    }
  } else {
    activeMovements = undefined;
  }
}

function onDwell(seconds) {
  validate(seconds >= 0);
  writeBlock("CYCL DEF 9.0 " + localize("DWELL TIME"));
  writeBlock("CYCL DEF 9.1 DWELL " + secFormat.format(seconds));
}

function onParameter(name, value) {
  if (name == "operation-structure-comment") {
    writeStructureComment("  " + value);
  }
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(
    "TOOL CALL " + spindleAxisTable.lookup(spindleAxis) + " S" + rpmFormat.format(spindleSpeed)
  );
}

function onDrilling(cycle) {
  writeBlock("CYCL DEF 200 " + localize("DRILLING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q202=" + xyzFormat.format(cycle.depth) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
    + "  Q210=" + secFormat.format(0) + " ;" + localize("DWELL AT TOP") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q211=" + secFormat.format(0) + " ;" + localize("DWELL AT BOTTOM")
  );
}

function onCounterBoring(cycle) {
  writeBlock("CYCL DEF 200 " + localize("DRILLING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q202=" + xyzFormat.format(cycle.depth) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
    + "  Q210=" + secFormat.format(0) + " ;" + localize("DWELL AT TOP") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM")
  );
}

function onChipBreaking(cycle) {
  writeBlock("CYCL DEF 203 " + localize("UNIVERSAL DRILLING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q202=" + xyzFormat.format(cycle.incrementalDepth) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
    + "  Q210=" + secFormat.format(0) + " ;" + localize("DWELL AT TOP") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q212=" + xyzFormat.format(cycle.incrementalDepthReduction) + " ;" + localize("DECREMENT") + " ~" + EOL
    + "  Q213=" + cycle.plungesPerRetract + " ;" + localize("BREAKS") + " ~" + EOL
    + "  Q205=" + xyzFormat.format(cycle.minimumIncrementalDepth) + " ;" + localize("MIN. PLUNGING DEPTH") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL TIME AT DEPTH") + " ~" + EOL
    + "  Q208=" + "MAX" + " ;" + localize("RETRACTION FEED RATE") + " ~" + EOL
    + "  Q256=" + xyzFormat.format((cycle.chipBreakDistance != undefined) ? cycle.chipBreakDistance : machineParameters.chipBreakingDistance) + " ;" + localize("DIST. FOR CHIP BRKNG")
  );
}

function onDeepDrilling(cycle) {
  if (useCycl205) {
    writeBlock("CYCL DEF 205 " + localize("UNIVERSAL PECKING") + " ~" + EOL
      + " Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
      + " Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
      + " Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
      + " Q202=" + xyzFormat.format(cycle.incrementalDepth) + " ;" + localize("PLUNGING DEPTH") + " ~" + EOL
      + " Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
      + " Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
      + " Q212=" + xyzFormat.format(cycle.incrementalDepthReduction) + " ;" + localize("DECREMENT") + " ~" + EOL
      + " Q205=" + xyzFormat.format(cycle.minimumIncrementalDepth) + " ;" + localize("MIN. PLUNGING DEPTH") + " ~" + EOL
      + " Q258=" + xyzFormat.format(0.5) + " ;" + localize("UPPER ADV. STOP DIST.") + " ~" + EOL
      + " Q259=" + xyzFormat.format(1) + " ;" + localize("LOWER ADV. STOP DIST.") + " ~" + EOL
      + " Q257=" + xyzFormat.format(5) + " ;" + localize("DEPTH FOR CHIP BRKNG") + " ~" + EOL
      + " Q256=" + xyzFormat.format((cycle.chipBreakDistance != undefined) ? cycle.chipBreakDistance : machineParameters.chipBreakingDistance) + " ;" + localize("DIST. FOR CHIP BRKNG")+ " ~" + EOL
      + " Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL TIME AT DEPTH") + " ~" + EOL
      + " Q379=" + "0" + " ;" + localize("STARTING POINT") + " ~" + EOL
      + " Q253=" + feedFormat.format(cycle.retractFeedrate) + " ;" + localize("F PRE-POSITIONING")
    );
  } else {
    writeBlock("CYCL DEF 200 " + localize("DRILLING") + " ~" + EOL
      + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
      + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
      + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
      + "  Q202=" + xyzFormat.format(cycle.incrementalDepth) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
      + "  Q210=" + secFormat.format(0) + " ;" + localize("DWELL AT TOP") + " ~" + EOL
      + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
      + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
      + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM")
    );
  }
}

function onGunDrilling(cycle) {
  var coolantCode = getCoolantCode(tool.coolant);
  writeBlock("CYCL DEF 241 " + localize("SINGLE-FLUTED DEEP-HOLE DRILLING") + " ~" + EOL
    + " Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + " Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + " Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + " Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL TIME AT DEPTH") + " ~" + EOL
    + " Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + " Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + " Q379=" + xyzFormat.format(cycle.startingDepth) + " ;" + localize("STARTING POINT") + " ~" + EOL
    + " Q253=" + feedFormat.format(cycle.positioningFeedrate) + " ;" + localize("F PRE-POSITIONING") + " ~" + EOL
    + " Q208=" + feedFormat.format(cycle.retractFeedrate) + " ;" + localize("RETRACT FEED RATE") + " ~" + EOL
    + " Q426=" + (cycle.stopSpindle ? 5 : (tool.clockwise ? 3 : 4)) + " ;" + localize("DIR. OF SPINDLE ROT.") + " ~" + EOL
    + " Q427=" + rpmFormat.format(cycle.positioningSpindleSpeed ? cycle.positioningSpindleSpeed : tool.spindleRPM) + " ;" + localize("ENTRY EXIT SPEED") + " ~" + EOL
    + " Q428=" + rpmFormat.format(tool.spindleRPM) + " ;" + localize("DRILLING SPEED") + " ~" + EOL
    + conditional(coolantCode, " Q429=" + (coolantCode ? coolantCode[0] : 0) + " ;" + localize("COOLANT ON") + " ~" + EOL)
    + conditional(coolantCode, " Q430=" + (coolantCode ? coolantCode[1] : 0) + " ;" + localize("COOLANT OFF") + " ~" + EOL)
    // Heidenhain manual doesn't specify Q435 fully - adjust to fit CNC
    + " Q435=" + xyzFormat.format(cycle.dwellDepth ? (cycle.depth + cycle.dwellDepth) : 0) + " ;" + localize("DWELL DEPTH") // 0 to disable
  );
}

function onTapping(cycle) {
  writeBlock("CYCL DEF 207 " + localize("RIGID TAPPING NEW") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q239=" + pitchFormat.format((tool.type == TOOL_TAP_LEFT_HAND ? -1 : 1) * tool.threadPitch) + " ;" + localize("THREAD PITCH") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE")
  );
}

function onTappingWithChipBreaking(cycle) {
  writeBlock("CYCL DEF 209 " + localize("TAPPING W/ CHIP BRKG") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q239=" + pitchFormat.format((tool.type == TOOL_TAP_LEFT_HAND ? -1 : 1) * tool.threadPitch) + " ;" + localize("THREAD PITCH") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q257=" + xyzFormat.format(cycle.incrementalDepth) + " ;" + localize("DEPTH FOR CHIP BRKNG") + " ~" + EOL
    + "  Q256=" + xyzFormat.format((cycle.chipBreakDistance != undefined) ? cycle.chipBreakDistance : machineParameters.chipBreakingDistance) + " ;" + localize("DIST. FOR CHIP BRKNG") + " ~" + EOL
    + "  Q336=" + angleFormat.format(0) + " ;" + localize("ANGLE OF SPINDLE")
  );
}

function onReaming(cycle) {
  writeBlock("CYCL DEF 201 " + localize("REAMING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM") + " ~" + EOL
    + "  Q208=" + feedFormat.format(cycle.retractFeedrate) + " ;" + localize("RETRACTION FEED TIME") + " ~" + EOL // retract at reaming feed rate
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE")
  );
}

function onStopBoring(cycle) {
  writeBlock("CYCL DEF 202 " + localize("BORING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM") + " ~" + EOL
    + "  Q208=" + "MAX" + " ;" + localize("RETRACTION FEED RATE") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q214=" + 0 + " ;" + localize("DISENGAGING DIRECTION") + " ~" + EOL
    + "  Q336=" + angleFormat.format(0) + " ;" + localize("ANGLE OF SPINDLE")
  );
}

/** Returns the best discrete disengagement direction for the specified direction. */
function getDisengagementDirection(direction) {
  switch (getQuadrant(direction + 45 * Math.PI/180)) {
  case 0:
    return 3;
  case 1:
    return 4;
  case 2:
    return 1;
  case 3:
    return 2;
  }
  error(localize("Invalid disengagement direction."));
  return 3;
}

function onFineBoring(cycle) {
  // we do not support cycle.shift
  
  writeBlock("CYCL DEF 202 " + localize("BORING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM") + " ~" + EOL
    + "  Q208=" + "MAX" + " ;" + localize("RETRACTION FEED TIME") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q214=" + getDisengagementDirection(cycle.shiftDirection) + " ;" + localize("DISENGAGING DIRECTION") + " ~" + EOL
    + "  Q336=" + angleFormat.format(cycle.compensatedShiftOrientation) + " ;" + localize("ANGLE OF SPINDLE")
  );
}

function onBackBoring(cycle) {
  writeBlock("CYCL DEF 204 " + localize("BACK BORING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q249=" + xyzFormat.format(cycle.backBoreDistance) + " ;" + localize("DEPTH REDUCTION") + " ~" + EOL
    + "  Q250=" + xyzFormat.format(cycle.depth) + " ;" + localize("MATERIAL THICKNESS") + " ~" + EOL
    + "  Q251=" + xyzFormat.format(cycle.shift) + " ;" + localize("OFF-CENTER DISTANCE") + " ~" + EOL
    + "  Q252=" + xyzFormat.format(0) + " ;" + localize("TOOL EDGE HEIGHT") + " ~" + EOL
    + "  Q253=" + "MAX" + " ;"+ localize("F PRE-POSITIONING") + " ~" + EOL
    + "  Q254=" + feedFormat.format(cycle.feedrate) + " ;" + localize("F COUNTERBORING") + " ~" + EOL
    + "  Q255=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q214=" + getDisengagementDirection(cycle.shiftDirection) + " ;" + localize("DISENGAGING DIRECTION") + " ~" + EOL
    + "  Q336=" + angleFormat.format(cycle.compensatedShiftOrientation) + " ;" + localize("ANGLE OF SPINDLE")
  );
}

function onBoring(cycle) {
  writeBlock("CYCL DEF 202 " + localize("BORING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q211=" + secFormat.format(cycle.dwell) + " ;" + localize("DWELL AT BOTTOM") + " ~" + EOL
    + "  Q208=" + feedFormat.format(cycle.retractFeedrate) + " ;" + localize("RETRACTION FEED RATE") + " ~" + EOL // retract at feed
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q214=" + 0 + " ;" + localize("DISENGAGING DIRECTION") + " ~" + EOL
    + "  Q336=" + angleFormat.format(0) + " ;" + localize("ANGLE OF SPINDLE")
  );
}

function onBoreMilling(cycle) {
  writeBlock("CYCL DEF 208 " + localize("BORE MILLING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q334=" + pitchFormat.format(cycle.pitch) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q335=" + xyzFormat.format(cycle.diameter) + " ;" + localize("NOMINAL DIAMETER") + " ~" + EOL
    + "  Q342=" + xyzFormat.format(tool.diameter) + " ;" + localize("ROUGHING DIAMETER")
  );
}

function onThreadMilling(cycle) {
  cycle.numberOfThreads = 1;
  writeBlock("CYCL DEF 262 " + localize("THREAD MILLING") + " ~" + EOL
    + "  Q335=" + xyzFormat.format(cycle.diameter) + " ;" + localize("NOMINAL DIAMETER") + " ~" + EOL
    // + for right-hand and - for left-hand
    + "  Q239=" + pitchFormat.format(cycle.threading == "right" ? cycle.pitch : -cycle.pitch) + " ;" + localize("PITCH") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("THREAD DEPTH") + " ~" + EOL
    // 0 for threads over entire depth
    + "  Q355=" + xyzFormat.format(cycle.numberOfThreads) + " ;" + localize("THREADS PER STEP") + " ~" + EOL
    + "  Q253=" + feedFormat.format(cycle.feedrate) + " ;" + localize("F PRE-POSITIONING") + " ~" + EOL
    + "  Q351=" + xyzFormat.format(cycle.direction == "climb" ? 1 : -1) + " ;" + localize("CLIMB OR UP-CUT") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q207=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR MILLING")
  );
}

function onCircularPocketMilling(cycle) {
  if (tool.taperAngle > 0) {
    error(localize("Circular pocket milling is not supported for taper tools."));
    return;
  }
  
  // do NOT use with undercutting - doesnt move to the center before retracting
  writeBlock("CYCL DEF 252 " + localize("CIRCULAR POCKET") + " ~" + EOL
    + "  Q215=1 ;" + localize("MACHINE OPERATION") + " ~" + EOL
    + "  Q223=" + xyzFormat.format(cycle.diameter) + " ;" + localize("CIRCLE DIAMETER") + " ~" + EOL
    + "  Q368=" + xyzFormat.format(0) + " ;" + localize("FINISHING ALLOWANCE FOR SIDE") + " ~" + EOL
    + "  Q207=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR MILLING") + " ~" + EOL
    + "  Q351=" + xyzFormat.format(cycle.direction == "climb" ? 1 : -1) + " ;" + localize("CLIMB OR UP-CUT") + " ~" + EOL
    + "  Q201=" + xyzFormat.format(-cycle.depth) + " ;" + localize("DEPTH") + " ~" + EOL
    + "  Q202=" + xyzFormat.format(cycle.incrementalDepth) + " ;" + localize("INFEED DEPTH") + " ~" + EOL
    + "  Q369=" + xyzFormat.format(0) + " ;" + localize("FINISHING ALLOWANCE FOR FLOOR") + " ~" + EOL
    + "  Q206=" + feedFormat.format(cycle.plungeFeedrate) + " ;" + localize("FEED RATE FOR PLUNGING") + " ~" + EOL
    + "  Q338=0 ;" + localize("INFEED FOR FINISHING") + " ~" + EOL
    + "  Q200=" + xyzFormat.format(cycle.retract - cycle.stock) + " ;" + localize("SET-UP CLEARANCE") + " ~" + EOL
    + "  Q203=" + xyzFormat.format(cycle.stock) + " ;" + localize("SURFACE COORDINATE") + " ~" + EOL
    + "  Q204=" + xyzFormat.format(cycle.clearance - cycle.stock) + " ;" + localize("2ND SET-UP CLEARANCE") + " ~" + EOL
    + "  Q370=" + ratioFormat.format(cycle.stepover/(tool.diameter/2)) + " ;" + localize("TOOL PATH OVERLAP") + " ~" + EOL
    + "  Q366=" + "0" + " ;" + localize("PLUNGING") + " ~" + EOL
    + "  Q385=" + feedFormat.format(cycle.feedrate) + " ;" + localize("FEED RATE FOR FINISHING")
  );
}

var expandCurrentCycle = false;

function onCycle() {
  if (!isSameDirection(getRotation().forward, new Vector(0, 0, 1))) {
    expandCurrentCycle = properties.expandCycles;
    if (!expandCurrentCycle) {
      cycleNotSupported();
    }
    return;
  }
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
    return;
  }

  expandCurrentCycle = false;

  if (cycle.clearance != undefined) {
    if (getCurrentPosition().z < cycle.clearance) {
      writeBlock("L" + zOutput.format(cycle.clearance) + radiusCompensationTable.lookup(radiusCompensation) + " FMAX");
      setCurrentPositionZ(cycle.clearance);
    }
  }

  switch (cycleType) {
  case "drilling": // G81 style
    onDrilling(cycle);
    break;
  case "counter-boring":
    onCounterBoring(cycle);
    break;
  case "chip-breaking":
    onChipBreaking(cycle);
    break;
  case "deep-drilling":
    onDeepDrilling(cycle);
    break;
  case "gun-drilling":
    onGunDrilling(cycle);
    break;
  case "tapping":
  case "left-tapping":
  case "right-tapping":
    onTapping(cycle);
    break;
  case "tapping-with-chip-breaking":
  case "left-tapping-with-chip-breaking":
  case "right-tapping-with-chip-breaking":
    onTappingWithChipBreaking(cycle);
    break;
  case "reaming":
    onReaming(cycle);
    break;
  case "stop-boring":
    onStopBoring(cycle);
    break;
  case "fine-boring":
    onFineBoring(cycle);
    break;
  case "back-boring":
    onBackBoring(cycle);
    break;
  case "boring":
    onBoring(cycle);
    break;
  case "bore-milling":
    if (cycle.numberOfSteps > 1) {
      expandCurrentCycle = properties.expandCycles;
      if (!expandCurrentCycle) {
        cycleNotSupported();
      }
    } else {
      onBoreMilling(cycle);
    }
    break;
  case "thread-milling":
    if (cycle.numberOfSteps > 1) {
      expandCurrentCycle = properties.expandCycles;
      if (!expandCurrentCycle) {
        cycleNotSupported();
      }
    } else {
      onThreadMilling(cycle);
    }
    break;
  case "circular-pocket-milling":
    onCircularPocketMilling(cycle);
    break;
  default:
    expandCurrentCycle = properties.expandCycles;
    if (!expandCurrentCycle) {
      cycleNotSupported();
    }
  }
}

function onCyclePoint(x, y, z) {
  if (!expandCurrentCycle) {
    // execute current cycle after this positioning block
/*
    if (cycleType == "circular-pocket-milling") {
      if (isFirstCyclePoint()) {
        onCircularPocketFinishMilling(x, y, cycle);
        writeBlock("CYCL CALL");
      } else {
        writeBlock("FN 0: Q216 = " + xyzFormat.format(x));
        writeBlock("FN 0: Q217 = " + xyzFormat.format(y));
        writeBlock("CYCL CALL");
        xOutput.reset();
        yOutput.reset();
      }
    } else {
      writeBlock("L" + xOutput.format(x) + yOutput.format(y) + " FMAX " + mFormat.format(99));
    }
*/
    writeBlock("L" + xOutput.format(x) + yOutput.format(y) + " FMAX " + mFormat.format(99));
  } else {
    expandCyclePoint(x, y, z);
  }
}

function onCycleEnd() {
  zOutput.reset();
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
  pendingRadiusCompensation = radiusCompensation;
}

function onRapid(x, y, z) {
  var xyz = xOutput.format(x) + yOutput.format(y) + zOutput.format(z);
  if (xyz) {
    pendingRadiusCompensation = -1;
    writeBlock("L" + xyz + radiusCompensationTable.lookup(radiusCompensation) + " FMAX");
  }
  forceFeed();
}

function onLinear(x, y, z, feed) {
  var xyz = xOutput.format(x) + yOutput.format(y) + zOutput.format(z);
  var f = getFeed(feed);
  if (xyz) {
    pendingRadiusCompensation = -1;
    writeBlock("L" + xyz + radiusCompensationTable.lookup(radiusCompensation) + f);
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      forceFeed(); // force feed on next line
    } else {
      pendingRadiusCompensation = -1;
      writeBlock("L" + radiusCompensationTable.lookup(radiusCompensation) + f);
    }
  }
}

function onRapid5D(x, y, z, a, b, c) {
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for 5-axis move."));
    return;
  }

  if (currentSection.isOptimizedForMachine()) {
    var xyzabc = xOutput.format(x) + yOutput.format(y) + zOutput.format(z) + aOutput.format(a) + bOutput.format(b) + cOutput.format(c);
    if (xyzabc) {
      writeBlock("L" + xyzabc + radiusCompensationTable.lookup(radiusCompensation) + " FMAX");
    }
  } else {
    forceXYZ(); // required
    var pt = xOutput.format(x) + yOutput.format(y) + zOutput.format(z) + txOutput.format(a) + tyOutput.format(b) + tzOutput.format(c);
    if (pt) {
      pendingRadiusCompensation = -1;
      writeBlock("LN" + pt + radiusCompensationTable.lookup(radiusCompensation) + " FMAX");
    }
  }
  forceFeed(); // force feed on next line
}

function onLinear5D(x, y, z, a, b, c, feed) {
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for 5-axis move."));
    return;
  }

  if (currentSection.isOptimizedForMachine()) {
    var xyzabc = xOutput.format(x) + yOutput.format(y) + zOutput.format(z) + aOutput.format(a) + bOutput.format(b) + cOutput.format(c);
    var f = getFeed(feed);
    if (xyzabc) {
      writeBlock("L" + xyzabc + radiusCompensationTable.lookup(radiusCompensation) + f);
    } else if (f) {
      if (getNextRecord().isMotion()) { // try not to output feed without motion
        forceFeed(); // force feed on next line
      } else {
        pendingRadiusCompensation = -1;
        writeBlock("L" + radiusCompensationTable.lookup(radiusCompensation) + f);
      }
    }
  } else {
    forceXYZ(); // required
    var pt = xOutput.format(x) + yOutput.format(y) + zOutput.format(z) + txOutput.format(a) + tyOutput.format(b) + tzOutput.format(c);
    var f = getFeed(feed);
    if (pt) {
      pendingRadiusCompensation = -1;
      writeBlock("LN" + pt + radiusCompensationTable.lookup(radiusCompensation) + f);
    } else if (f) {
      if (getNextRecord().isMotion()) { // try not to output feed without motion
        forceFeed(); // force feed on next line
      } else {
        pendingRadiusCompensation = -1;
        writeBlock("LN" + radiusCompensationTable.lookup(radiusCompensation) + f);
      }
    }
  }
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
    return;
  }

  switch (getCircularPlane()) {
  case PLANE_XY:
    writeBlock("CC X" + xyzFormat.format(cx) + " Y" + xyzFormat.format(cy));
    break;
  case PLANE_ZX:
    if (isHelical()) {
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
      return;
    }
    writeBlock("CC X" + xyzFormat.format(cx) + " Z" + xyzFormat.format(cz));
    break;
  case PLANE_YZ:
    if (isHelical()) {
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
      return;
    }
    writeBlock("CC Y" + xyzFormat.format(cy) + " Z" + xyzFormat.format(cz));
    break;
  default:
    var t = tolerance;
    if ((t == 0) && hasParameter("operation:tolerance")) {
      t = getParameter("operation:tolerance");
    }
    linearize(t);
    return;
  }

  if (false && !isHelical() && (Math.abs(getCircularSweep()) <= 2*Math.PI*0.9)) { // use IPA to avoid radius compensation errors
    switch (getCircularPlane()) {
    case PLANE_XY:
      writeBlock(
        "C" + xOutput.format(x) + yOutput.format(y) +
        (clockwise ? " DR-" : " DR+") +
        radiusCompensationTable.lookup(radiusCompensation) +
        getFeed(feed)
      );
      break;
    case PLANE_ZX:
      writeBlock(
        "C" + xOutput.format(x) + zOutput.format(z) +
        (clockwise ? " DR-" : " DR+") +
        radiusCompensationTable.lookup(radiusCompensation) +
        getFeed(feed)
      );
      break;
    case PLANE_YZ:
      writeBlock(
        "C" + yOutput.format(y) + zOutput.format(z) +
        (clockwise ? " DR-" : " DR+") +
        radiusCompensationTable.lookup(radiusCompensation) +
        getFeed(feed)
      );
      break;
    default:
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
    }
    return;
  }

  if (isHelical()) {
    if (getCircularPlane() == PLANE_XY) {
      // IPA must have same sign as DR
      var sweep = (clockwise ? -1 : 1) * Math.abs(getCircularSweep());
      var block = "CP IPA" + paFormat.format(sweep) + zOutput.format(z);
      block += clockwise ? " DR-" : " DR+";
      block += /*radiusCompensationTable.lookup(radiusCompensation) +*/ getFeed(feed);
      writeBlock(block);
      xOutput.reset();
      yOutput.reset();
    } else {
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
    }
  } else {
    // IPA must have same sign as DR
    var sweep = (clockwise ? -1 : 1) * Math.abs(getCircularSweep());
    var block = "CP IPA" + paFormat.format(sweep);
    block += clockwise ? " DR-" : " DR+";
    block += /*radiusCompensationTable.lookup(radiusCompensation) +*/ getFeed(feed);
    writeBlock(block);
    
    switch (getCircularPlane()) {
    case PLANE_XY:
      xOutput.reset();
      yOutput.reset();
      break;
    case PLANE_ZX:
      xOutput.reset();
      zOutput.reset();
      break;
    case PLANE_YZ:
      yOutput.reset();
      zOutput.reset();
      break;
    default:
      invalidateXYZ();
    }
  }
}

var currentCoolantMode = undefined;

function forceCoolant() {
  currentCoolantMode = undefined;
}

/** Used for gun drilling. */
function getCoolantCode(coolant) {
  switch (coolant) {
  case COOLANT_OFF:
    break;
  case COOLANT_FLOOD:
    return [8, 9];
  case COOLANT_MIST:
  case COOLANT_THROUGH_TOOL:
    return [7, 9];
  case COOLANT_AIR:
    return [25, 9];
  case COOLANT_AIR_THROUGH_TOOL:
    return [26, 9];
  default:
    onUnsupportedCoolant(coolant);
  }
  return undefined;
}

function setCoolant(coolant) {
  if (coolant == currentCoolantMode) {
    return; // coolant is already active
  }
  
  var m;
  switch (coolant) {
  case COOLANT_OFF:
    m = 9;
    break;
  case COOLANT_FLOOD:
    m = 8;
    break;
  case COOLANT_MIST:
  case COOLANT_THROUGH_TOOL:
    m = 7;
    break;
  case COOLANT_AIR:
    m = 25;
    break;
  case COOLANT_AIR_THROUGH_TOOL:
    m = 26;
    break;
  default:
    onUnsupportedCoolant(coolant);
    m = 9;
  }
  
  if (m) {
    writeBlock(mFormat.format(m));
    currentCoolantMode = coolant;
  }
}

var mapCommand = {
  COMMAND_STOP:0,
  COMMAND_OPTIONAL_STOP:1,
  COMMAND_END:30,
  COMMAND_SPINDLE_CLOCKWISE:3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE:4,
  // COMMAND_START_SPINDLE
  COMMAND_STOP_SPINDLE:5
  //COMMAND_ORIENTATE_SPINDLE:19,
  //COMMAND_LOAD_TOOL:6, // do not use
  //COMMAND_COOLANT_ON,
  //COMMAND_COOLANT_OFF,
  //COMMAND_ACTIVATE_SPEED_FEED_SYNCHRONIZATION
  //COMMAND_DEACTIVATE_SPEED_FEED_SYNCHRONIZATION
};

function onCommand(command) {
  switch (command) {
  case COMMAND_COOLANT_OFF:
    setCoolant(COOLANT_OFF);
    return;
  case COMMAND_COOLANT_ON:
    setCoolant(COOLANT_FLOOD);
    return;
  case COMMAND_START_SPINDLE:
    onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
    return;
  case COMMAND_LOCK_MULTI_AXIS:
    return;
  case COMMAND_UNLOCK_MULTI_AXIS:
    return;
  case COMMAND_START_CHIP_TRANSPORT:
    return;
  case COMMAND_STOP_CHIP_TRANSPORT:
    return;
  case COMMAND_BREAK_CONTROL:
    return;
  case COMMAND_TOOL_MEASURE:
    return;
  }
  
  var stringId = getCommandStringId(command);
  var mcode = mapCommand[stringId];
  if (mcode != undefined) {
    writeBlock(mFormat.format(mcode));
  } else {
    onUnsupportedCommand(command);
  }
}

function onSectionEnd() {
  if (currentSection.isMultiAxis()) {
    if (properties.useFunctionTCPM) {
      writeBlock("FUNCTION RESET TCPM");
    } else {
      writeBlock(mFormat.format(129));
    }
  }
  invalidate();
}

function onClose() {
  optionalSection = false;
  
  setTolerance(0);
  setCoolant(COOLANT_OFF);

  setWorkPlane(new Vector(0, 0, 0), false); // reset working plane - we turn below

  if (getNumberOfSections() > 0) {
    onCommand(COMMAND_BREAK_CONTROL);
  }

  onCommand(COMMAND_STOP_SPINDLE);

  if (useCycl247) {
    writeBlock(
      "CYCL DEF 247 " + localize("DATUM SETTING") + " ~" + EOL +
      "  Q339=" + 0 + " ; " + localize("DATUM NUMBER")
    );
  } else {
    //writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
    //writeBlock("CYCL DEF 7.1 #" + 0);
  }

  onCommand(COMMAND_UNLOCK_MULTI_AXIS);

  writeBlock("L Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));

  var homeXY = "";
  if (machineConfiguration.hasHomePositionX()) {
    homeXY += " X" + xyzFormat.format(machineConfiguration.getHomePositionX());
  }
  if (machineConfiguration.hasHomePositionY()) {
    homeXY += " Y" + xyzFormat.format(machineConfiguration.getHomePositionY());
  }
  if (homeXY) {
    writeBlock("L" + homeXY + " R0 FMAX " + mFormat.format(properties.useM92 ? 92 : 91));
  }

  if (machineConfiguration.isMultiAxisConfiguration()) {
    if ((getNumberOfSections() == 0) ||
        isSameDirection(getSection(getNumberOfSections() - 1).getGlobalFinalToolAxis(), new Vector(0, 0, 1))) {
      // simple retract
      writeBlock(
        "L" +
        conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(0)) +
        conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(0)) +
        conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(0)) +
        " FMAX " + mFormat.format(94)
      );
    } else {
      // full safe retract - for very large parts
      // keep tilt
      writeBlock(
        "L" +
        conditional(machineConfiguration.isMachineCoordinate(0) && isSameDirection(machineConfiguration.getAxisByCoordinate(0).getAxis(), machineConfiguration.getSpindleAxis()), " A" + abcFormat.format(0)) +
        conditional(machineConfiguration.isMachineCoordinate(1) && isSameDirection(machineConfiguration.getAxisByCoordinate(1).getAxis(), machineConfiguration.getSpindleAxis()), " B" + abcFormat.format(0)) +
        conditional(machineConfiguration.isMachineCoordinate(2) && isSameDirection(machineConfiguration.getAxisByCoordinate(2).getAxis(), machineConfiguration.getSpindleAxis()), " C" + abcFormat.format(0)) +
        " FMAX " + mFormat.format(94)
      );
    }
  }

  if (forceMultiAxisIndexing || !is3D() || machineConfiguration.isMultiAxisConfiguration()) {
    writeBlock(mFormat.format(127)); // cancel shortest path traverse
  }

  onCommand(COMMAND_STOP_CHIP_TRANSPORT);
  writeBlock(mFormat.format(30)); // stop program, spindle stop, coolant off

  writeBlock(
    "END PGM" + (programName ? (SP + programName) : "") + ((unit == MM) ? " MM" : " INCH")
  );
}
