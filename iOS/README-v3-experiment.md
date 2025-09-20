# V3 Realtime API Experiment

## Overview
This branch contains an experimental implementation using OpenAI's Realtime API for ultra-low latency voice interaction.

## What Was Achieved
- Successfully integrated OpenAI Realtime API
- Achieved 396ms voice-to-voice latency
- Solved echo/feedback loop issues
- Attempted ReadyPlayer.Me 3D avatar integration

## Why This Approach Was Abandoned
- Voice quality was significantly degraded compared to ElevenLabs
- For a Stoic philosopher character, voice quality and personality are more important than latency
- iOS SceneKit/RealityKit cannot natively load GLB files from ReadyPlayer.Me
- USDZ conversion pipeline was overly complex for the benefit

## Technical Learnings
- OpenAI Realtime API works but voice quality is limiting factor
- iOS 3D avatar pipeline requires Unity for proper ReadyPlayer.Me support
- Echo prevention in bidirectional audio requires careful grace period management

## Decision
Reverted to V2 architecture (OpenAI Completions + ElevenLabs TTS) to prioritize character personality and voice quality over latency.