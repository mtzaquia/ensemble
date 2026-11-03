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

// Source lifecycle is kept separate from presentation observation. Both ViewData shapes handled
// by AsyncContent provide their concrete, strongly typed data here without snapshot erasure.
final class AsyncContentSourceObservation {
    private var identity: ObjectIdentifier?
    private var task: Task<Void, Never>?

    func bind<Value>(to data: ViewData<Value>) {
        let identity = ObjectIdentifier(data)
        guard self.identity != identity || (data.binding != nil && task == nil) else { return }
        task?.cancel()
        task = nil
        self.identity = identity
        if data.binding != nil {
            task = Task { await data.observe() }
        }
    }

    isolated deinit {
        task?.cancel()
    }
}
