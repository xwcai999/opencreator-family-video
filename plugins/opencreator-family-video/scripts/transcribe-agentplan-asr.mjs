import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import WebSocket from "./vendor/ws/index.js";

const ENDPOINT = "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async";
const RESOURCE_ID = "volc.seedasr.sauc.duration";
const PACKET_DURATION_MS = 200;
const PACKET_BYTES = 6400;
const apiKey = process.env.ARK_API_KEY?.trim();
const cliArgs = process.argv.slice(2);
const selfTestMode = cliArgs[0] === "--self-test";
const [inputPath, outputPath, expectedScriptPath] = selfTestMode ? [] : cliArgs;
const MATCH_THRESHOLD = 0.72;
const MATCH_STOPWORDS = new Set(["a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "with", "is", "are", "am", "be", "it", "this", "that", "now"]);

if (selfTestMode) {
  const selfTest = runSelfTest();
  console.log(JSON.stringify(selfTest));
  process.exit(selfTest.failed === 0 ? 0 : 1);
}

if (!apiKey) throw new Error("缺少 ARK_API_KEY 环境变量。");
if (!inputPath || !outputPath) {
  throw new Error("用法：node transcribe-agentplan-asr.mjs <input.wav> <output.json> [expected-script.json]；离线自检：node transcribe-agentplan-asr.mjs --self-test");
}

const expectedScript = expectedScriptPath ? loadExpectedScript(expectedScriptPath) : null;

const wav = fs.readFileSync(inputPath);
if (wav.length <= 44) throw new Error("输入 WAV 为空或无效。");

const requestId = crypto.randomUUID();
const rawResponses = [];
let traceId;
let latestPayload = {};
let audioStarted = false;
let settled = false;
let handshakeTimer;
let finalTimer;

const headers = {
  "X-Api-Key": apiKey,
  "X-Api-Resource-Id": RESOURCE_ID,
  "X-Api-Request-Id": requestId,
  "X-Api-Connect-Id": requestId,
  "X-Api-Sequence": "-1",
};

const fullRequest = {
  user: { uid: "claw-video-subtitles" },
  audio: {
    format: "wav",
    codec: "raw",
    rate: 16000,
    bits: 16,
    channel: 1,
    language: "zh-CN",
  },
  request: {
    model_name: "bigmodel",
    enable_itn: true,
    enable_punc: true,
    enable_ddc: true,
    show_utterances: true,
    enable_nonstream: true,
    enable_speaker_info: true,
    ssd_version: "200",
    result_type: "full",
  },
};

const result = await new Promise((resolve, reject) => {
  const socket = new WebSocket(ENDPOINT, { headers });

  const cleanup = () => {
    clearTimeout(handshakeTimer);
    clearTimeout(finalTimer);
  };

  const fail = (error) => {
    if (settled) return;
    settled = true;
    cleanup();
    socket.terminate();
    reject(error instanceof Error ? error : new Error(String(error)));
  };

  const finish = () => {
    if (settled) return;
    settled = true;
    cleanup();
    socket.close();
    const utterances = normalizeUtterances(latestPayload?.result?.utterances);
    const segments = normalizeSegments(latestPayload?.result?.segments, utterances);
    const text = typeof latestPayload?.result?.text === "string"
      ? latestPayload.result.text.trim()
      : "";
    const matchEvidence = expectedScript
      ? buildMatchEvidence(expectedScript, segments, utterances)
      : createNotRequestedMatchEvidence();
    resolve({
      text,
      utterances,
      segments,
      match_evidence: matchEvidence,
      has_speech: Boolean(text || utterances.length || segments.length),
    });
  };

  const sendAudio = async () => {
    try {
      const packets = [];
      for (let offset = 0; offset < wav.length; offset += PACKET_BYTES) {
        packets.push(wav.subarray(offset, Math.min(offset + PACKET_BYTES, wav.length)));
      }
      const startedAt = performance.now();
      for (let index = 0; index < packets.length; index += 1) {
        if (settled) return;
        const last = index === packets.length - 1;
        socket.send(buildFrame(2, last ? 3 : 1, 0, 1, last ? -(index + 2) : index + 2, packets[index]));
        if (!last) {
          const waitMs = Math.max(0, startedAt + (index + 1) * PACKET_DURATION_MS - performance.now());
          await delay(waitMs);
        }
      }
      finalTimer = setTimeout(() => fail(new Error("等待 Agent Plan ASR 最终响应超时。")), 30000);
    } catch (error) {
      fail(error);
    }
  };

  handshakeTimer = setTimeout(() => fail(new Error("连接 Agent Plan ASR 超时。")), 15000);

  socket.on("upgrade", (response) => {
    traceId = headerValue(response.headers, "x-tt-logid") ?? traceId;
  });
  socket.on("open", () => {
    const payload = Buffer.from(JSON.stringify(fullRequest), "utf8");
    socket.send(buildFrame(1, 1, 1, 1, 1, payload));
  });
  socket.on("message", (data) => {
    try {
      const frame = parseFrame(Buffer.from(data));
      rawResponses.push({
        message_type: frame.messageType,
        sequence: frame.sequence ?? null,
        is_last_package: frame.isLastPackage,
        error_code: frame.errorCode ?? null,
        payload: frame.payload ?? null,
        raw_payload_text: frame.payload ? undefined : frame.rawPayloadText,
      });
      if (frame.messageType === "error") {
        fail(new Error(`Agent Plan ASR 服务端错误 ${frame.errorCode ?? ""}：${frame.payload?.message ?? frame.rawPayloadText ?? "未知错误"}`));
        return;
      }
      if (frame.payload) latestPayload = frame.payload;
      if (!audioStarted) {
        audioStarted = true;
        clearTimeout(handshakeTimer);
        void sendAudio();
      }
      if (frame.isLastPackage) finish();
    } catch (error) {
      fail(error);
    }
  });
  socket.on("error", fail);
  socket.on("close", (code, reason) => {
    if (!settled) fail(new Error(`Agent Plan ASR 异常关闭：${code} ${reason.toString()}`.trim()));
  });
});

const output = {
  generated_at: new Date().toISOString(),
  provider: "Volcengine Ark Agent Plan",
  endpoint: ENDPOINT,
  resource_id: RESOURCE_ID,
  model: "doubao-seed-asr-2.0",

  request_id: requestId,
  trace_id: traceId ?? null,
  input: {
    file: path.resolve(inputPath),
    bytes: wav.length,
    sha256: crypto.createHash("sha256").update(wav).digest("hex"),
  },
  expected_script: expectedScript
    ? {
        file: path.resolve(expectedScriptPath),
        sha256: crypto.createHash("sha256").update(fs.readFileSync(expectedScriptPath)).digest("hex"),
        line_count: expectedScript.length,
      }
    : null,
  result,
  raw_responses: rawResponses,
};

fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
console.log(JSON.stringify({
  ok: true,
  has_speech: result.has_speech,
  text: result.text,
  segments: result.segments.length,
  all_matched: result.match_evidence.all_matched,
  trace_id: traceId ?? null,
  output: path.resolve(outputPath),
}));

function loadExpectedScript(filePath) {
  const resolvedPath = path.resolve(filePath);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
  } catch (error) {
    throw new Error(`expected dialogue JSON 无法读取或解析：${resolvedPath}：${error.message}`);
  }

  const lines = Array.isArray(parsed)
    ? parsed
    : parsed?.dialogue ?? parsed?.sentences ?? parsed?.lines ?? parsed?.utterances;
  if (!Array.isArray(lines) || lines.length === 0) {
    throw new Error("expected dialogue JSON 必须包含非空 dialogue/sentences 数组。");
  }

  return lines.map((line, index) => {
    const value = typeof line === "string" ? { english: line } : line;
    if (!value || typeof value !== "object") {
      throw new Error(`expected dialogue 第 ${index + 1} 行不是字符串或对象。`);
    }
    const english = firstString(value.english, value.text, value.target_english, value.targetEnglish);
    if (!english) {
      throw new Error(`expected dialogue 第 ${index + 1} 行缺少 english/text。`);
    }
    const keywords = Array.isArray(value.keywords)
      ? value.keywords.filter((item) => typeof item === "string" && item.trim())
      : [];
    return {
      line_index: index,
      speaker: firstString(value.speaker, value.role) ?? null,
      english,
      chinese: firstString(value.chinese, value.translation, value.zh) ?? null,
      keywords,
      start_hint_ms: finiteNumber(value.start_hint_ms),
      end_hint_ms: finiteNumber(value.end_hint_ms),
    };
  });
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function normalizeUtterances(items) {
  if (!Array.isArray(items)) return [];
  return items
    .filter((item) => typeof item?.text === "string" && item.text.trim())
    .map((item, index) => {
      const words = normalizeWordItems(item.words);
      const timedWords = words.filter((word) => validTimeRange(word.start_ms, word.end_ms) && alignmentTokens(word.text).length > 0);
      const startMs = finiteNumber(item.start_time) ?? (timedWords[0]?.start_ms ?? null);
      const endMs = finiteNumber(item.end_time) ?? (timedWords.at(-1)?.end_ms ?? null);
      return {
        utterance_index: index,
        text: item.text.trim(),
        normalized_text: normalizeEnglishText(item.text),
        start_ms: startMs,
        end_ms: endMs,
        definite: item.definite === true,
        speaker_id: item.speaker_id ?? item.additions?.speaker_id ?? null,
        words,
      };
    });
}

function normalizeWordItems(items) {
  if (!Array.isArray(items)) return [];
  return items
    .map((item, index) => ({
      word_index: index,
      text: typeof item?.text === "string" ? item.text.trim() : "",
      start_ms: finiteNumber(item?.start_time),
      end_ms: finiteNumber(item?.end_time),
    }))
    .filter((word) => word.text);
}

function normalizeSegments(providerSegments, utterances) {
  const providerItems = Array.isArray(providerSegments)
    ? providerSegments
    : (Array.isArray(providerSegments?.segments) ? providerSegments.segments : []);
  if (providerItems.length > 0) {
    return providerItems
      .filter((item) => typeof item?.text === "string" && item.text.trim())
      .map((item, index) => {
        const words = normalizeWordItems(item.words);
        const timedWords = words.filter((word) => validTimeRange(word.start_ms, word.end_ms) && alignmentTokens(word.text).length > 0);
        return {
          segment_index: index,
          utterance_index: finiteInteger(item.utterance_index) ?? null,
          text: item.text.trim(),
          normalized_text: normalizeEnglishText(item.text),
          start_ms: finiteNumber(item.start_time) ?? (timedWords[0]?.start_ms ?? null),
          end_ms: finiteNumber(item.end_time) ?? (timedWords.at(-1)?.end_ms ?? null),
          definite: item.definite === true,
          speaker_id: item.speaker_id ?? item.additions?.speaker_id ?? null,
          time_source: "provider",
          words,
        };
      });
  }

  const segments = [];
  for (const utterance of utterances) {
    const sentences = splitSentenceTexts(utterance.text);
    const timedWords = utterance.words.filter((word) => validTimeRange(word.start_ms, word.end_ms) && alignmentTokens(word.text).length > 0);
    let wordCursor = 0;
    for (const sentence of sentences) {
      const sentenceTokens = alignmentTokens(sentence);
      const wordCount = sentenceTokens.length;
      let sentenceWords = [];
      let timeSource = "utterance";
      if (wordCount > 0 && wordCursor + wordCount <= timedWords.length) {
        sentenceWords = timedWords.slice(wordCursor, wordCursor + wordCount);
        wordCursor += wordCount;
        timeSource = "word_times";
      }
      const startMs = sentenceWords[0]?.start_ms ?? utterance.start_ms;
      const endMs = sentenceWords.at(-1)?.end_ms ?? utterance.end_ms;
      segments.push({
        segment_index: segments.length,
        utterance_index: utterance.utterance_index,
        text: sentence,
        normalized_text: normalizeEnglishText(sentence),
        start_ms: startMs,
        end_ms: endMs,
        definite: utterance.definite,
        speaker_id: utterance.speaker_id,
        time_source: timeSource,
        words: sentenceWords,
      });
    }
  }
  return segments;
}

function splitSentenceTexts(value) {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) return [];
  const matches = text.match(/[^.!?。！？]+(?:[.!?。！？]+|$)/gu);
  return (matches && matches.length ? matches : [text]).map((item) => item.trim()).filter(Boolean);
}

function createNotRequestedMatchEvidence() {
  return {
    requested: false,

    status: "not_requested",
    all_matched: null,
    order_ok: null,
    expected_count: 0,
    actual_count: 0,
    matched_count: 0,
    missing_lines: [],
    extra_segments: [],
    line_matches: [],
  };
}

function buildMatchEvidence(expectedLines, segments, utterances) {
  const actualSegments = Array.isArray(segments) && segments.length
    ? segments
    : utterances.map((utterance, index) => ({
        ...utterance,
        segment_index: index,
        normalized_text: normalizeEnglishText(utterance.text),
      }));
  const actualAnalyses = actualSegments.map((segment) => analyzeText(segment.text));
  const unrestricted = expectedLines.map((line) => {
    let best = null;
    for (let index = 0; index < actualAnalyses.length; index += 1) {
      const candidate = scoreLine(line, actualAnalyses[index]);
      if (!best || candidate.score > best.score) best = { segment_index: index, ...candidate };
    }
    return best;
  });

  const usedSegments = new Set();
  const lineMatches = [];
  let cursor = 0;
  for (const line of expectedLines) {
    let best = null;
    for (let index = cursor; index < actualAnalyses.length; index += 1) {
      const candidate = scoreLine(line, actualAnalyses[index]);
      if (!best || candidate.score > best.score) best = { segment_index: index, ...candidate };
    }

    const segment = best ? actualSegments[best.segment_index] : null;
    const accepted = Boolean(best && best.score >= MATCH_THRESHOLD && best.core_coverage >= 1 &&
      best.missing_keywords.length === 0 && best.unexpected_english_tokens.length === 0);
    if (best && best.score >= MATCH_THRESHOLD && best.core_coverage >= 1) {
      usedSegments.add(best.segment_index);
      cursor = best.segment_index + 1;
    }
    lineMatches.push({
      line_index: line.line_index,
      speaker: line.speaker,
      expected_english: line.english,
      expected_chinese: line.chinese,
      expected_start_hint_ms: line.start_hint_ms,
      expected_end_hint_ms: line.end_hint_ms,
      expected_normalized: normalizeEnglishText(line.english),
      actual_segment_index: segment ? best.segment_index : null,
      actual_text: segment?.text ?? null,
      actual_normalized: segment?.normalized_text ?? null,
      matched: accepted,
      similarity: best?.similarity ?? 0,
      score: best?.score ?? 0,
      core_coverage: best?.core_coverage ?? 0,
      missing_tokens: best?.missing_tokens ?? normalizeEnglishTokens(line.english),
      unexpected_tokens: best?.unexpected_english_tokens ?? [],
      missing_core_tokens: best?.missing_core_tokens ?? coreTokens(line.english),
      missing_keywords: best?.missing_keywords ?? normalizeEnglishTokens(line.keywords),
      start_ms: segment?.start_ms ?? null,
      end_ms: segment?.end_ms ?? null,
      speaker_id: segment?.speaker_id ?? null,
      reason: accepted ? "matched" : (best ? "text_or_keyword_mismatch" : "missing_segment"),
    });
  }

  const missingLines = lineMatches.filter((line) => !line.matched);
  const extraSegments = actualSegments
    .filter((_, index) => !usedSegments.has(index))
    .map((segment) => ({
      segment_index: segment.segment_index,
      text: segment.text,
      normalized_text: segment.normalized_text,
      start_ms: segment.start_ms,
      end_ms: segment.end_ms,
      speaker_id: segment.speaker_id,
      english_like: analyzeText(segment.text).english_like,
    }));
  const extraEnglishSegments = extraSegments.filter((segment) => segment.english_like);
  const lineUnexpectedEnglish = lineMatches.some((line) => line.unexpected_tokens.length > 0);
  const strongUnrestricted = unrestricted
    .map((candidate) => candidate && candidate.score >= MATCH_THRESHOLD && candidate.core_coverage >= 1 ? candidate.segment_index : null)
    .filter((index) => index !== null);
  const orderOk = strongUnrestricted.every((index, position) => position === 0 || index > strongUnrestricted[position - 1]);
  const allMatched = missingLines.length === 0 && orderOk && extraEnglishSegments.length === 0 && !lineUnexpectedEnglish;

  return {
    requested: true,
    status: allMatched ? "passed" : "failed",
    all_matched: allMatched,
    order_ok: orderOk,
    expected_count: expectedLines.length,
    actual_count: actualSegments.length,
    matched_count: lineMatches.filter((line) => line.matched).length,
    missing_lines: missingLines,
    extra_segments: extraSegments,
    extra_english_segments: extraEnglishSegments,
    line_matches: lineMatches,
  };
}

function scoreLine(expectedLine, actualAnalysis) {
  const rawExpectedTokens = normalizeEnglishTokens(expectedLine.english);
  const rawActualTokens = actualAnalysis.tokens;
  // 对英文对白只用英文 token 比对，允许同一时间段尾随中文笑声/非语言声；
  // 额外可辨识英文仍通过 unexpected_english_tokens 进入失败门禁。
  const expectedTokens = rawExpectedTokens.some(isEnglishToken)
    ? rawExpectedTokens.filter(isEnglishToken)
    : rawExpectedTokens;
  const actualTokens = expectedTokens.some(isEnglishToken)
    ? rawActualTokens.filter(isEnglishToken)
    : rawActualTokens;
  const expectedCore = coreTokens(expectedTokens);
  const missingTokens = multisetDifference(expectedTokens, actualTokens);
  const unexpectedEnglishTokens = multisetDifference(rawActualTokens.filter(isEnglishToken), rawExpectedTokens.filter(isEnglishToken));
  const missingCoreTokens = multisetDifference(expectedCore, actualTokens);
  const keywordTokens = normalizeEnglishTokens(expectedLine.keywords);
  const missingKeywords = multisetDifference(keywordTokens, actualTokens);
  const coreCoverage = expectedCore.length === 0
    ? (expectedTokens.length ? (missingTokens.length ? 0 : 1) : 0)
    : (expectedCore.length - missingCoreTokens.length) / expectedCore.length;
  const similarity = tokenSimilarity(expectedTokens, actualTokens);
  const score = Math.max(0, Math.min(1, similarity * 0.65 + coreCoverage * 0.35));
  return { similarity, score, core_coverage: coreCoverage, missing_tokens: missingTokens, unexpected_english_tokens: unexpectedEnglishTokens, missing_core_tokens: missingCoreTokens, missing_keywords: missingKeywords };
}

function analyzeText(value) {
  const tokens = normalizeEnglishTokens(value);
  return { tokens, english_like: tokens.some(isEnglishToken) };
}

function normalizeEnglishText(value) {
  return normalizeEnglishTokens(value).join(" ");
}

function normalizeEnglishTokens(value) {
  if (Array.isArray(value)) {
    return value.flatMap((item) => normalizeEnglishTokens(item));
  }
  const text = typeof value === "string" ? value.normalize("NFKC").toLowerCase() : "";
  const tokens = text.match(/[a-z0-9]+(?:['’][a-z0-9]+)?|[\p{Script=Han}]/gu) ?? [];
  return tokens.map((token) => {
    const normalized = token.replace(/[\u2018\u2019']/g, "");
    return normalized === "okay" ? "ok" : normalized;
  }).filter(Boolean);
}

function alignmentTokens(value) {
  return normalizeEnglishTokens(value);
}

function coreTokens(value) {
  const tokens = Array.isArray(value) ? value : normalizeEnglishTokens(value);
  const core = tokens.filter((token) => !MATCH_STOPWORDS.has(token));
  return core.length ? core : tokens;
}

function multisetDifference(expected, actual) {
  const remaining = new Map();
  for (const token of actual) remaining.set(token, (remaining.get(token) ?? 0) + 1);
  const missing = [];
  for (const token of expected) {
    const count = remaining.get(token) ?? 0;
    if (count > 0) remaining.set(token, count - 1);
    else missing.push(token);
  }
  return missing;
}

function tokenSimilarity(expected, actual) {
  if (expected.length === 0 && actual.length === 0) return 1;
  if (expected.length === 0 || actual.length === 0) return 0;
  const rows = Array.from({ length: expected.length + 1 }, (_, row) => {

    const values = new Array(actual.length + 1).fill(0);
    values[0] = row;
    return values;
  });
  for (let column = 0; column <= actual.length; column += 1) rows[0][column] = column;
  for (let row = 1; row <= expected.length; row += 1) {
    for (let column = 1; column <= actual.length; column += 1) {
      const substitution = rows[row - 1][column - 1] + (expected[row - 1] === actual[column - 1] ? 0 : 1);
      rows[row][column] = Math.min(rows[row - 1][column] + 1, rows[row][column - 1] + 1, substitution);
    }
  }
  return Math.max(0, 1 - rows[expected.length][actual.length] / Math.max(expected.length, actual.length));
}

function isEnglishToken(token) {
  return typeof token === "string" && /^[a-z0-9]+$/i.test(token);
}

function validTimeRange(startMs, endMs) {
  return typeof startMs === "number" && Number.isFinite(startMs) && startMs >= 0 &&
    typeof endMs === "number" && Number.isFinite(endMs) && endMs >= startMs;
}

function finiteInteger(value) {
  return Number.isInteger(value) ? value : null;
}

function runSelfTest() {
  const ordered = [
    selfTestSegment(0, "Let's make a star.", 352, 1552),
    selfTestSegment(1, "OK, and a face.", 2112, 3712),
    selfTestSegment(2, "Perfect, now a flower.", 4232, 6112),
  ];
  const expected = [
    { line_index: 0, english: "Let's make a star.", keywords: [] },
    { line_index: 1, english: "OK, and a face.", keywords: [] },
    { line_index: 2, english: "Perfect, now a flower.", keywords: [] },
  ];
  const cases = [
    {
      name: "normal",
      actual: ordered,
      expected,
      pass: (e) => e.all_matched && e.order_ok && e.missing_lines.length === 0 && e.extra_segments.length === 0,
    },
    {
      name: "missing_keyword",
      actual: ordered,
      expected: [{ ...expected[0], english: "Let's make a moon." }, expected[1], expected[2]],
      pass: (e) => !e.all_matched && e.missing_lines.some((line) => line.line_index === 0),
    },
    {
      name: "extra_dialogue",
      actual: [ordered[0], selfTestSegment(1, "Look over here.", 1600, 2000), ordered[1], ordered[2]],
      expected,
      pass: (e) => !e.all_matched && e.extra_english_segments.some((segment) => segment.text === "Look over here."),
    },
    {
      name: "reordered",
      actual: [ordered[1], ordered[0], ordered[2]],
      expected,
      pass: (e) => !e.all_matched && !e.order_ok,
    },
  ];
  const results = cases.map((testCase) => {
    const evidence = buildMatchEvidence(testCase.expected, testCase.actual, []);
    const passed = testCase.pass(evidence);
    return {
      name: testCase.name,
      status: passed ? "PASS" : "FAIL",
      all_matched: evidence.all_matched,
      order_ok: evidence.order_ok,
      missing_lines: evidence.missing_lines.map((line) => line.line_index),
      extra_segments: evidence.extra_segments.map((segment) => segment.text),
    };
  });
  const passCount = results.filter((result) => result.status === "PASS").length;
  return {
    ok: passCount === results.length,
    event: "self_test",
    pass_count: passCount,
    total: results.length,
    failed: results.length - passCount,
    cases: results,
  };
}

function selfTestSegment(segmentIndex, text, startMs, endMs) {
  return {
    segment_index: segmentIndex,
    utterance_index: segmentIndex,
    text,
    normalized_text: normalizeEnglishText(text),
    start_ms: startMs,
    end_ms: endMs,
    definite: true,
    speaker_id: "0",
    time_source: "fixture",
    words: [],
  };
}

function buildFrame(messageType, flags, serialization, compression, sequence, payload) {
  const compressed = zlib.gzipSync(payload);
  const frame = Buffer.alloc(12 + compressed.length);
  frame[0] = 0x11;
  frame[1] = (messageType << 4) | flags;
  frame[2] = (serialization << 4) | compression;
  frame[3] = 0;
  frame.writeInt32BE(sequence, 4);
  frame.writeUInt32BE(compressed.length, 8);
  compressed.copy(frame, 12);
  return frame;
}

function parseFrame(frame) {
  if (frame.length < 4) throw new Error("Agent Plan 响应帧长度不足。");
  const headerSize = (frame[0] & 0x0f) * 4;
  const messageTypeValue = frame[1] >> 4;
  const flags = frame[1] & 0x0f;
  const serialization = frame[2] >> 4;
  const compression = frame[2] & 0x0f;
  let offset = headerSize;
  let sequence;
  if ((flags & 1) !== 0) {
    ensure(frame, offset, 4);
    sequence = frame.readInt32BE(offset);
    offset += 4;
  }
  if ((flags & 4) !== 0) {
    ensure(frame, offset, 4);
    offset += 4;
  }
  let errorCode;
  if (messageTypeValue === 15) {
    ensure(frame, offset, 4);
    errorCode = frame.readUInt32BE(offset);
    offset += 4;
  } else if (messageTypeValue !== 9) {
    throw new Error(`Agent Plan 返回不支持的消息类型：${messageTypeValue}。`);
  }
  ensure(frame, offset, 4);
  const size = frame.readUInt32BE(offset);
  offset += 4;
  ensure(frame, offset, size);
  let payloadBytes = frame.subarray(offset, offset + size);
  if (compression === 1 && payloadBytes.length) payloadBytes = zlib.gunzipSync(payloadBytes);
  const rawPayloadText = payloadBytes.toString("utf8");
  let payload;
  if (rawPayloadText && serialization === 1) payload = JSON.parse(rawPayloadText);
  return {
    messageType: messageTypeValue === 15 ? "error" : "response",
    sequence,
    isLastPackage: (flags & 2) !== 0,
    errorCode,
    payload,
    rawPayloadText,
  };
}

function ensure(buffer, offset, length) {
  if (offset < 0 || length < 0 || offset + length > buffer.length) {
    throw new Error("Agent Plan 响应帧载荷长度无效。");
  }
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function headerValue(headersObject, name) {
  const key = Object.keys(headersObject).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  const value = key ? headersObject[key] : undefined;
  return Array.isArray(value) ? value[0] : value;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

























