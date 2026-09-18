//
//  Copyright (c) 2026 @mtzaquia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import SwiftUI

extension EnvironmentValues {
    @Entry var ensemblePhaseAnimation: Animation? = nil
}

extension View {
    /// Sets the animation used when descendant async content changes phase.
    ///
    /// The configuration cascades through the environment to ``AsyncContent`` instances. Apply it
    /// to one instance or an enclosing view to configure a region. A nearer modifier overrides the
    /// inherited configuration, including when its animation is `nil`.
    ///
    /// Changes between empty, loading, successful, and failed phases receive this animation after
    /// initial presentation. This includes placeholder replacement and policy-driven insertion or
    /// removal, such as hidden loading content becoming visible on success. Each instance forwards
    /// its own presentation update in an animated transaction, so a surrounding `List` can animate
    /// its structural changes without an additional `.animation` modifier. Neighboring rows can
    /// move as the container reflows; unrelated presentation updates are not wrapped in this
    /// animation. Animatable changes inside the rendered subtree can also animate.
    ///
    /// A non-`nil` animation replaces the inherited transaction's animation on phase changes, unless
    /// animations are disabled. The default, and an explicit `nil`, supply no phase animation and
    /// preserve the inherited transaction. Same-phase value updates and insertion or removal of the
    /// entire instance by an ancestor remain consumer-owned. This modifier does not choose a SwiftUI
    /// transition or change content identity.
    ///
    /// - Parameter animation: The animation for descendant post-mount phase changes, or `nil` to
    ///   clear inherited phase-animation configuration without removing the caller's animation.
    /// - Returns: A view with the phase-animation configuration in its environment.
    public func phaseAnimation(_ animation: Animation?) -> some View {
        environment(\.ensemblePhaseAnimation, animation)
    }
}
