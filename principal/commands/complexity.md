---
---
description: Analyze time and space complexity of code, with optimization suggestions
---

Given the code or algorithm in $ARGUMENTS (or read the file if a path is provided):

1. **Identify the algorithm or code block** to analyze. If a file path is given, read the file first.

2. **Time complexity analysis:**
   - Identify every loop, recursion, and data structure operation
   - For each: state the complexity and why
   - Derive the total time complexity using the composition rules:
     - Sequential: O(f) + O(g) = O(max(f, g))
     - Nested: O(f) × O(g)
     - Recursive: solve the recurrence relation
   - State the best case, average case, and worst case if they differ

3. **Space complexity analysis:**
   - Stack depth (recursion)
   - Auxiliary data structures (arrays, maps, sets created)
   - Input vs output space (is the operation in-place?)

4. **Practical impact at scale:**
   | Input size | Operations (current) | Time estimate |
   |-----------|---------------------|---------------|
   | 100 | | |
   | 10,000 | | |
   | 1,000,000 | | |

5. **Optimization suggestions** (if the complexity can be improved):
   - What the optimal complexity is for this problem class
   - What algorithm or data structure achieves it
   - Whether the optimization is worth it at the expected input size

6. Present as: "Current: O([X]) time, O([Y]) space. Optimal: O([A]) time, O([B]) space. Worth optimizing: [yes/no] because [reason]."

---
