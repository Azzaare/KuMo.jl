using GLMakie
using KuMo

agent = show_interactive_run(; fps=10)
foreach(_ -> node!(agent, KuMo.Node(50)), 1:4)

link!(agent, 1, 2, KuMo.FreeLink())
link!(agent, 2, 3, KuMo.FreeLink())
link!(agent, 3, 4, KuMo.FreeLink())
link!(agent, 4, 1, KuMo.FreeLink())

foreach(_ -> data!(agent, rand(1:4)), 1:2)
foreach(_ -> user!(agent, rand(1:4)), 1:2)

@async job!(agent, 0, 1, 1, 0, 2, 2, 0.01; stop=10.0)

sleep(2)
@async job!(agent, 0, 1, 1, 0, 1, 1, 0.01; stop=5.0)

sleep(10)
stop!(agent)
