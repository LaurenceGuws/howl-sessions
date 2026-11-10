function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const message = gl.getShaderInfoLog(shader) || 'shader compile failed';
    gl.deleteShader(shader);
    throw new Error(message);
  }
  return shader;
}

function link(gl, vertex, fragment) {
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertex));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragment));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
  }
  return program;
}

export function clippedSprite(destination, clip, source) {
  const [dx, dy, dw, dh] = destination;
  const [cx, cy, cw, ch] = clip;
  const [sx, sy, sw, sh] = source;
  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0 || cw <= 0 || ch <= 0) return null;
  const left = Math.max(dx, cx), top = Math.max(dy, cy);
  const right = Math.min(dx + dw, cx + cw), bottom = Math.min(dy + dh, cy + ch);
  if (right <= left || bottom <= top) return null;
  const scaleX = sw / dw, scaleY = sh / dh;
  return {
    destination:[left, top, right - left, bottom - top],
    source:[
      sx + (left - dx) * scaleX,
      sy + (top - dy) * scaleY,
      (right - left) * scaleX,
      (bottom - top) * scaleY,
    ],
  };
}

function integralScale(destination, source) {
  const dw = destination[2], dh = destination[3];
  const sw = source[2], sh = source[3];
  if (!Number.isInteger(dw) || !Number.isInteger(dh) ||
      !Number.isInteger(sw) || !Number.isInteger(sh) ||
      sw <= 0 || sh <= 0 || dw < sw || dh < sh)
    return false;
  return dw % sw === 0 && dh % sh === 0;
}

export function webglFrameEligible(frame) {
  for (const command of frame.commands) {
    if (command.k === 0) continue;
    if (command.k !== 1) return false;
    const visible = clippedSprite(command.d, command.c, command.s);
    if (visible && !integralScale(command.d, command.s)) return false;
  }
  return true;
}

export class WebGLTerminalBackend {
  constructor({glyphCoverageLut}) {
    this.canvas = document.createElement('canvas');
    const gl = this.canvas.getContext('webgl2', {
      alpha:false,
      antialias:false,
      depth:false,
      stencil:false,
      premultipliedAlpha:false,
      preserveDrawingBuffer:false,
    });
    if (!gl) throw new Error('WebGL2 terminal backend unavailable');
    this.gl = gl;
    this.coverage = glyphCoverageLut;
    this.resources = new Map();

    const vertex = `#version 300 es
      precision highp float;
      precision highp int;
      layout(location=0) in vec4 dst;
      layout(location=1) in vec4 src;
      layout(location=2) in vec4 rgba;
      uniform vec2 surface;
      uniform int mode;
      flat out vec4 instanceDst;
      flat out vec4 instanceSrc;
      flat out vec4 tint;
      void main() {
        vec2 corner = vec2(
          (gl_VertexID == 1 || gl_VertexID == 3) ? 1.0 : 0.0,
          (gl_VertexID >= 2) ? 1.0 : 0.0
        );
        vec2 point = dst.xy + corner * dst.zw;
        gl_Position = vec4(
          point.x / surface.x * 2.0 - 1.0,
          1.0 - point.y / surface.y * 2.0,
          0.0, 1.0
        );
        instanceDst = dst;
        instanceSrc = src;
        tint = rgba / 255.0;
      }`;
    const fragment = `#version 300 es
      precision highp float;
      precision highp int;
      uniform sampler2D tex;
      uniform vec2 surface;
      uniform int mode;
      flat in vec4 instanceDst;
      flat in vec4 instanceSrc;
      flat in vec4 tint;
      out vec4 outColor;
      void main() {
        if (mode == 0) {
          outColor = tint;
          return;
        }
        vec2 pixel = vec2(
          floor(gl_FragCoord.x),
          floor(surface.y - gl_FragCoord.y)
        );
        vec2 sourcePoint = instanceSrc.xy +
          (pixel - instanceDst.xy + vec2(0.5)) *
            (instanceSrc.zw / instanceDst.zw);
        ivec2 texel = ivec2(floor(sourcePoint));
        ivec2 limit = textureSize(tex, 0) - ivec2(1);
        texel = clamp(texel, ivec2(0), limit);
        float coverage = texelFetch(tex, texel, 0).r;
        outColor = vec4(tint.rgb, tint.a * coverage);
      }`;

    this.program = link(gl, vertex, fragment);
    this.surfaceUniform = gl.getUniformLocation(this.program, 'surface');
    this.modeUniform = gl.getUniformLocation(this.program, 'mode');
    this.textureUniform = gl.getUniformLocation(this.program, 'tex');

    this.vao = gl.createVertexArray();
    this.buffer = gl.createBuffer();
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    const stride = 12 * Float32Array.BYTES_PER_ELEMENT;
    for (let location = 0; location < 3; location += 1) {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(
        location,
        4,
        gl.FLOAT,
        false,
        stride,
        location * 4 * Float32Array.BYTES_PER_ELEMENT,
      );
      gl.vertexAttribDivisor(location, 1);
    }

    gl.useProgram(this.program);
    gl.uniform1i(this.textureUniform, 0);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);

    this.instances = new Float32Array(1024 * 12);
    this.count = 0;
    this.batchKey = null;
    this.batchMode = -1;
    this.batchResource = null;
    this.drawCalls = 0;
  }

  resourceCount() {
    return this.resources.size;
  }

  reset() {
    for (const resource of this.resources.values()) this.gl.deleteTexture(resource.texture);
    this.resources.clear();
    this.canvas.width = 1;
    this.canvas.height = 1;
  }

  ensureInstances(count) {
    if (count * 12 <= this.instances.length) return;
    let values = this.instances.length;
    while (values < count * 12) values *= 2;
    this.instances = new Float32Array(values);
  }

  createResource(upload, framePixels) {
    if (upload.f !== 0) return null;
    const gl = this.gl;
    const [width, height] = upload.z;
    if (width <= 0 || height <= 0 || upload.stride <= 0) throw new Error('invalid WebGL resource geometry');
    const pixels = new Uint8Array(width * height);
    for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
      pixels[y * width + x] = this.coverage[framePixels[upload.o + y * upload.stride + x]];
    }
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
    return {format:upload.f, width, height, texture};
  }

  deleteResource(key) {
    const resource = this.resources.get(key);
    if (!resource) return;
    this.gl.deleteTexture(resource.texture);
    this.resources.delete(key);
  }

  syncResources(frame, framePixels, resourceKey) {
    for (const qualified of frame.removals) this.deleteResource(resourceKey(qualified));
    for (const upload of frame.uploads) {
      const key = resourceKey(upload.q);
      this.deleteResource(key);
      const resource = this.createResource(upload, framePixels);
      if (resource) this.resources.set(key, resource);
    }
    const live = new Set();
    for (const command of frame.commands) if (command.k === 1) live.add(resourceKey(command.q));
    for (const key of [...this.resources.keys()]) if (!live.has(key)) this.deleteResource(key);
  }

  beginBatch(key, mode, resource) {
    this.batchKey = key;
    this.batchMode = mode;
    this.batchResource = resource;
    this.count = 0;
  }

  append(destination, source, color) {
    this.ensureInstances(this.count + 1);
    const offset = this.count * 12;
    this.instances.set(destination, offset);
    this.instances.set(source, offset + 4);
    this.instances.set(color, offset + 8);
    this.count += 1;
  }

  flush(surface) {
    if (this.count === 0) return;
    const gl = this.gl;
    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, this.instances.subarray(0, this.count * 12), gl.STREAM_DRAW);
    gl.uniform2f(this.surfaceUniform, surface[0], surface[1]);
    gl.uniform1i(this.modeUniform, this.batchMode);
    if (this.batchMode === 1) {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.batchResource.texture);
    }
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, this.count);
    this.drawCalls += 1;
    this.count = 0;
  }

  draw(frame, resourceKey) {
    if (!webglFrameEligible(frame)) throw new Error('frame is outside WebGL terminal admission');
    const gl = this.gl;
    const [width, height] = frame.surface;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    gl.viewport(0, 0, width, height);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    this.count = 0;
    this.batchKey = null;
    this.drawCalls = 0;
    for (const command of frame.commands) {
      if (command.k === 0) {
        if (this.batchKey !== 'solid') {
          this.flush(frame.surface);
          this.beginBatch('solid', 0, null);
        }
        this.append(command.r, [0, 0, 0, 0], command.color);
        continue;
      }
      const visible = clippedSprite(command.d, command.c, command.s);
      if (!visible) continue;
      const key = resourceKey(command.q);
      const resource = this.resources.get(key);
      if (!resource) throw new Error(`missing WebGL alpha resource ${key}`);
      const batchKey = `alpha:${key}`;
      if (this.batchKey !== batchKey) {
        this.flush(frame.surface);
        this.beginBatch(batchKey, 1, resource);
      }
      this.append(visible.destination, visible.source, command.color);
    }
    this.flush(frame.surface);
    if (gl.isContextLost()) throw new Error('WebGL2 terminal context lost');
    const error = gl.getError();
    if (error !== gl.NO_ERROR) throw new Error('WebGL2 terminal draw failed: ' + error);
    return {draw_calls:this.drawCalls};
  }
}
