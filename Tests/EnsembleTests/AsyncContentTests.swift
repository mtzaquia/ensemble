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
import Testing
@testable import Ensemble

@Suite("Async content")
struct AsyncContentTests {
    enum TestError: Error {
        case expected
    }

    @Test("The content and failure builder API composes")
    func buildersCompose() {
        let data = ViewData<Int>()

        _ = AsyncContent(data) { value, _ in
            Text("\(value)")
        }

        _ = AsyncContent(data) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        _ = AsyncContent(
            data,
            loading: .placeholder(0),
            failure: .replace
        ) { value, source in
            Text("\(value)-\(String(describing: source))")
        } failure: { error, retry in
            Button(error.localizedDescription) {
                retry?()
            }
        }

        _ = AsyncContent(data, loading: .cached, failure: .cached) { value, _ in
            Text("\(value)")
        }

        _ = AsyncContent(data, failure: .cached) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        _ = AsyncContent(data, failure: .hidden) { value, _ in
            Text("\(value)")
        }
    }

    @Test("A placeholder is used before the first successful value")
    func placeholderWithoutCachedValue() {
        let presentation = AsyncContentLoadingPolicy.placeholder(10).presentation(latest: nil)

        #expect(presentation?.value == 10)
        #expect(presentation?.source == .placeholder)
    }

    @Test("A placeholder policy prefers the latest successful value")
    func placeholderWithCachedValue() {
        let presentation = AsyncContentLoadingPolicy.placeholder(10).presentation(latest: 20)

        #expect(presentation?.value == 20)
        #expect(presentation?.source == .cached)
    }
}
