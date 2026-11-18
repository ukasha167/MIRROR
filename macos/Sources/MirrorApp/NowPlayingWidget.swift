import SwiftUI

/// Real-time synced media state from the paired Android phone.
public struct MediaPlaybackState: Equatable, Sendable {
    public var trackTitle: String
    public var artist: String
    public var isPlaying: Bool

    public static let empty = MediaPlaybackState(trackTitle: "", artist: "", isPlaying: false)

    public var isEmpty: Bool {
        trackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(trackTitle: String, artist: String, isPlaying: Bool) {
        self.trackTitle = trackTitle
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

/// Compact Now Playing module reflecting synced Android audio state (zero fake placeholder data).
public struct NowPlayingWidget: View {
    public let state: MediaPlaybackState

    public init(state: MediaPlaybackState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: MirrorTokens.space3) {
            Image(systemName: state.isEmpty ? "music.note" : (state.isPlaying ? "waveform" : "pause.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(MirrorTokens.accent))
                .frame(width: 32, height: 32)
                .background(MirrorTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.isEmpty ? "No Phone Media Playing" : state.trackTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(state.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if !state.artist.isEmpty {
                    Text(state.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !state.isEmpty {
                Text(state.isPlaying ? "Playing" : "Paused")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MirrorTokens.raisedSurface, in: Capsule())
            }
        }
        .padding(MirrorTokens.space3)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
    }
}
