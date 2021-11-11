# Simple struct that represents a graph via its edges
struct Graph
    n::Int # number of vertices (indices 1,...,n)
    edges::Set{Set{Int}} # edges, represented as sets of vertices

    function Graph(n::Integer, edges::Vector{Tuple{T, T}}) where T <: Integer
        n >= 1 || throw(DomainError("n must be a positive integer"))

        # Turn into set of sets
        edge_set = Set(Set.(edges))

        # Verify that all edges are valid
        all(edge -> edge ⊆ 1:n && length(edge) == 2, edge_set) || throw(ArgumentError("Some edges have invalid endpoints"))
        new(n, edge_set)
    end
end